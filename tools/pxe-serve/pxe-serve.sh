#!/usr/bin/env bash
set -euo pipefail

PROG="pxe-serve"

# Defaults
HTTP_PORT="8079"
IFACE=""
TARGET=""
NO_DHCP=""

usage() {
  cat >&2 <<EOF
Usage: $PROG [OPTIONS] <flake>#<machine> [interface]

Netboot a machine straight from its flake: builds the machine's netboot image
variant, serves it, and points PXE clients at it.

  $PROG .#<machine>

The machine needs a \`netboot\` entry in image.modules whose stage 1 fetches
the squashfs from store.url= (see e334411d, machines/atlas before it was
installed).
Everything is derived, so nothing has to be kept in sync by hand:

  * kernel, initrd and kernel command line come from the machine's netboot
    variant (\`system.build.images.netboot\`)
  * the iPXE script is generated against the serving interface's own address,
    which is the bit that is wrong in any pre-baked image the moment you move
    to a different network
  * kernel and initrd go over HTTP, because an initrd carrying a whole nix
    store is far too big for TFTP

By default this acts as a proxy DHCP server: it answers only the PXE boot
question and never hands out addresses, so it works on a network whose DHCP
server belongs to somebody else. The client must be on the same L2 segment.

Runs in the foreground. Press Ctrl+C to stop; the built payload stays in the
nix store, the served directory is temporary.

Options:
      --no-dhcp            Don't answer DHCP; only serve the files. Use when
                           another DHCP server already points clients at us.
      --http-port <port>   Port to serve kernel/initrd on (default: ${HTTP_PORT})
  -i, --interface <iface>  Interface to serve on
                           (default: the one carrying the default route)
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --no-dhcp)
      NO_DHCP=1
      shift
      ;;
    --http-port)
      HTTP_PORT="$2"
      shift 2
      ;;
    -i | --interface)
      IFACE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "$PROG: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z $TARGET ]]; then
        TARGET="$1"
      elif [[ -z $IFACE ]]; then
        IFACE="$1"
      else
        echo "$PROG: unexpected argument: $1" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z $TARGET ]]; then
  echo "$PROG: need a machine, e.g. $PROG .#<machine>" >&2
  usage
  exit 1
fi

# "<flake>#<machine>", or a bare machine name in the current flake.
if [[ $TARGET == *#* ]]; then
  FLAKE="${TARGET%%#*}"
  MACHINE="${TARGET##*#}"
else
  FLAKE="."
  MACHINE="$TARGET"
fi
[[ -n $FLAKE ]] || FLAKE="."

# builtins.getFlake (used for the iPXE override below) needs an absolute path
# or a URL, not a relative one like ".".
case $FLAKE in
  . | ./* | /* | ../*) FLAKE_REF=$(cd "$FLAKE" && pwd -P) ;;
  *) FLAKE_REF="$FLAKE" ;;
esac

if [[ -z $IFACE ]]; then
  IFACE=$(ip -4 route show default | awk '{print $5; exit}')
  if [[ -z $IFACE ]]; then
    echo "$PROG: no default route to pick an interface from; pass --interface" >&2
    exit 1
  fi
fi

ADDR=$(ip -4 -brief addr show dev "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -n1)
if [[ -z $ADDR ]]; then
  echo "$PROG: $IFACE has no IPv4 address to serve from" >&2
  exit 1
fi

CFG="${FLAKE}#nixosConfigurations.${MACHINE}.config.system.build.images.netboot.passthru.config"

echo "$PROG: building netboot payload for ${MACHINE} (this pulls in the whole store, so it takes a while)"
KERNEL=$(nix build --no-link --print-out-paths "${CFG}.system.build.kernel")
KERNEL_FILE=$(nix eval --raw "${CFG}.system.boot.loader.kernelFile")
INITRD=$(nix build --no-link --print-out-paths "${CFG}.system.build.netbootRamdisk")
TOPLEVEL=$(nix eval --raw "${CFG}.system.build.toplevel")
PARAMS=$(nix eval --raw --apply 'ps: builtins.concatStringsSep " " ps' "${CFG}.boot.kernelParams")
# Served separately from the initrd: iPXE can only hold so much in
# EfiBootServicesData, so stage 1 fetches this itself over HTTP.
SQUASHFS=$(nix build --no-link --print-out-paths "${CFG}.system.build.squashfsStore")

# iPXE gets the chain script baked in rather than asking DHCP for a filename.
# In proxy-DHCP mode dnsmasq answers through pxe-service, so a --dhcp-boot
# aimed at the second-stage (tag:ipxe) request never reaches iPXE and it dies
# with "Nothing to boot: No such file or directory" (ipxe.org/2d03e13b) right
# after loading. With the script embedded it only needs an address, which the
# network's own DHCP server hands out.
#
# Written to a file instead of passed inline because the expression embeds a
# URL and a flake path, and quoting that through the shell is a trap.
IPXE_EXPR=$(mktemp -t "${PROG}-ipxe-XXXXXX.nix")
cat >"$IPXE_EXPR" <<EOF
let
  flake = builtins.getFlake "${FLAKE_REF}";
in
flake.nixosConfigurations."${MACHINE}".pkgs.ipxe.override {
  embedScript = builtins.toFile "chain.ipxe" ''
    #!ipxe
    dhcp
    chain http://${ADDR}:${HTTP_PORT}/netboot.ipxe
  '';
}
EOF
IPXE=$(nix build --no-link --print-out-paths --impure --file "$IPXE_EXPR")
rm -f "$IPXE_EXPR"

# A stable directory rather than a mktemp one with a cleanup trap: the trap
# was the reason Ctrl+C did nothing useful. A bash INT handler does not exit
# after running, so it deleted the served directory out from under a still
# running dnsmasq and then went back to waiting. Only symlinks live here, so
# leaving them behind between runs costs nothing.
#
# Not under XDG_RUNTIME_DIR: dnsmasq drops privileges after startup, and
# /run/user/$UID is mode 0700, so the unprivileged dnsmasq cannot traverse it
# ("TFTP directory ... inaccessible: Permission denied", then it refuses to
# start). Everything served is a symlink into the world-readable nix store,
# so a world-traversable directory costs nothing.
ROOT="/var/tmp/${PROG}/${MACHINE}"
rm -rf "$ROOT"
mkdir -p "$ROOT"
chmod 755 "/var/tmp/${PROG}" "$ROOT"

ln -s "${KERNEL}/${KERNEL_FILE}" "$ROOT/bzImage"
ln -s "${INITRD}/initrd" "$ROOT/initrd"
ln -s "${SQUASHFS}" "$ROOT/nix-store.squashfs"
ln -s "${IPXE}/ipxe.efi" "$ROOT/ipxe.efi"
ln -s "${IPXE}/undionly.kpxe" "$ROOT/undionly.kpxe"

# store.url= is what stage 1 fetches the squashfs from; passing it on the
# command line instead of baking it into the image keeps the image valid when
# the serving address changes.
cat >"$ROOT/netboot.ipxe" <<EOF
#!ipxe
kernel http://${ADDR}:${HTTP_PORT}/bzImage init=${TOPLEVEL}/init initrd=initrd ${PARAMS} store.url=http://${ADDR}:${HTTP_PORT}/nix-store.squashfs
initrd http://${ADDR}:${HTTP_PORT}/initrd
boot
EOF

echo "$PROG: serving ${MACHINE} on ${IFACE} (${ADDR}) over http://${ADDR}:${HTTP_PORT}"
echo "$PROG: iPXE fetches $(stat -Lc %s "$ROOT/bzImage" | awk '{printf "%.0f MB", $1/1048576}') kernel + $(stat -Lc %s "$ROOT/initrd" | awk '{printf "%.0f MB", $1/1048576}') initrd; stage 1 then fetches $(stat -Lc %s "$ROOT/nix-store.squashfs" | awk '{printf "%.2f GB", $1/1073741824}') of store itself"

# exec, so there is no wrapper process between the terminal and dnsmasq: Ctrl+C
# reaches it directly and pxe-share's own trap does the privileged teardown
# (firewall rules, darkhttpd). pxe-share re-execs itself through sudo; the nix
# builds above deliberately ran as the calling user.
exec pxe-share ${NO_DHCP:+--no-dhcp} --http --http-port "$HTTP_PORT" "$ROOT" "$IFACE"
