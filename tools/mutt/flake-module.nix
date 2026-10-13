{ self, inputs, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      system,
      ...
    }:
    {
      packages.mutt =
        let
          notmuchConfig = self.packages.${system}.notmuch.passthru.configuration.configFile.path;

          inherit (pkgs) elinks;

          # Generate virtual-mailboxes from Maildir folder structure at build time
          # This discovers sieve folders dynamically — no hardcoded list needed
          genVirtualMailboxes = pkgs.writeShellScript "gen-virtual-mailboxes" ''
            maildir="$HOME/Maildir"
            [ -d "$maildir" ] || exit 0
            for dir in "$maildir"/.*; do
              [ -d "$dir/cur" ] || continue
              dotname=$(basename "$dir")
              # Display name without leading dot
              name=''${dotname#.}
              echo "virtual-mailboxes \"$name\" \"notmuch://?query=folder:$dotname\""
            done | sort
          '';

          mailcap = pkgs.writeText "mailcap" ''
            text/html; ${elinks}/bin/elinks -dump ; copiousoutput;
          '';

          # Script to view HTML emails in browser with embedded images
          viewHtmlBrowser = pkgs.writeShellScriptBin "view-html-browser" ''
                        set -euo pipefail
                        tmpfile=$(mktemp --suffix=.html)
                        trap 'rm -f "$tmpfile"' EXIT

                        ${pkgs.python3}/bin/python3 -c '
            import email, sys, base64

            msg = email.message_from_file(sys.stdin)

            # Build map of Content-ID -> base64 data URI
            cid_map = {}
            for part in msg.walk():
                cid = part.get("Content-ID", "").strip("<>")
                if cid and part.get_content_maintype() == "image":
                    data = part.get_payload(decode=True)
                    if data:
                        mime = part.get_content_type()
                        cid_map[cid] = f"data:{mime};base64,{base64.b64encode(data).decode()}"

            # Find HTML part
            html = None
            for part in msg.walk():
                if part.get_content_type() == "text/html":
                    payload = part.get_payload(decode=True)
                    charset = part.get_content_charset() or "utf-8"
                    html = payload.decode(charset, errors="replace")
                    break

            if html:
                for cid, data_uri in cid_map.items():
                    html = html.replace(f"cid:{cid}", data_uri)
                print(html)
            else:
                print("<html><body><p>No HTML content found.</p></body></html>")
            ' > "$tmpfile"

                        ${if pkgs.stdenv.isDarwin then "open" else "xdg-open"} "$tmpfile"
                        sleep 2
          '';

          msmtprc = pkgs.writeText "msmtprc" ''
            defaults
              logfile ~/.msmtp.log
              timeout 10
            account neoprism
              host neoprism.r
            account c-base
              from lassulus@c-base.org
              host c-mail.c-base.org
              port 465
              tls on
              tls_starttls off
              auth on
              user lassulus
              passwordeval rbw get --folder c-base shell.c-base.org --field password
            account clan-infra
              from infra@clan.lol
              host mail.clan.lol
              port 587
              tls on
              tls_starttls on
              auth on
              user infra@clan.lol
              passwordeval SOPS_AGE_KEY=$(rbw get --folder clan.lol clan-infra --field age-key) nix develop git+https://git.clan.lol/clan/clan-infra -c clan vars get --flake git+https://git.clan.lol/clan/clan-infra web01 infra-mail/infra-password
            account dedede
              from mail@dedede.org
              host mail.privateemail.com
              port 587
              tls on
              tls_starttls on
              auth on
              user mail@dedede.org
              passwordeval rbw get --folder dedede mail@dedede.org
            account default: neoprism
          '';

          msmtp = pkgs.writeShellScriptBin "msmtp" ''
            export NOTMUCH_CONFIG="${notmuchConfig}"

            # Save message to temporary file first
            tmpfile=$(mktemp)
            trap 'rm -f "$tmpfile"' EXIT
            cat > "$tmpfile"

            # Detect which account to use based on From: header in the email
            account=""
            from_line=$(grep -i "^From:" "$tmpfile" | head -1)
            if [[ "$from_line" =~ @c-base\.org ]]; then
              account="c-base"
            elif [[ "$from_line" =~ @clan\.lol ]]; then
              account="clan-infra"
            elif [[ "$from_line" =~ @dedede\.org ]]; then
              account="dedede"
            fi

            # For external accounts (c-base, clan-infra, dedede), always send directly
            if [ -n "$account" ]; then
              if ${pkgs.msmtp}/bin/msmtp -C ${msmtprc} -a "$account" "$@" < "$tmpfile"; then
                ${pkgs.notmuch}/bin/notmuch insert +sent < "$tmpfile"
                exit 0
              else
                exit 1
              fi
            fi

            # For default account, try neoprism.r first, fallback to SSH
            if ${pkgs.msmtp}/bin/msmtp -C ${msmtprc} "$@" < "$tmpfile" 2>/dev/null; then
              ${pkgs.notmuch}/bin/notmuch insert +sent < "$tmpfile"
              exit 0
            fi

            # If direct connection failed, fall back to SSH tunnel
            echo "Direct connection failed, sending via SSH..." >&2
            if ${pkgs.openssh}/bin/ssh -o ConnectTimeout=10 -p 45621 lass@neoprism.lassul.us 'msmtp -C /dev/null --host=localhost --port=25 --read-envelope-from --read-recipients' < "$tmpfile"; then
              ${pkgs.notmuch}/bin/notmuch insert +sent < "$tmpfile"
              exit 0
            else
              echo "Failed to send email" >&2
              exit 1
            fi
          '';

          muttrc = pkgs.writeText "muttrc" ''
            # read html mails
            auto_view text/html
            set mailcap_path = ${mailcap}

            # notmuch
            set folder="$HOME/Maildir"
            set nm_default_uri = "notmuch://$HOME/Maildir"
            set nm_record = yes
            set nm_record_tags = "-inbox me archive"
            set virtual_spoolfile
            set spoolfile = "notmuch://?query=folder:\"\" AND NOT tag:archive"

            set mail_check_stats
            set confirmappend = no
            set confirmcreate = no
            set mbox_type = Maildir
            set delete = yes
            set sendmail="${msmtp}/bin/msmtp"
            set from="lassulus@lassul.us"
            alternates ^.*@lassul\.us$ ^lassulus@c-base\.org$
            unset envelope_from_address
            set use_envelope_from
            set reverse_name
            set markers=no

            # Folder hooks: set alternates per-mailbox so identities don't overlap
            folder-hook . "unalternates *; alternates ^.*@lassul\\.us$ ^lassulus@c-base\\.org$; set from=lassulus@lassul.us"
            folder-hook "imaps://.*mail\\.clan\\.lol" "unalternates *; alternates ^.*@clan\\.lol$; set from=infra@clan.lol"
            folder-hook "imaps://.*mail\\.privateemail\\.com" "unalternates *; alternates ^.*@dedede\\.org$; set from=mail@dedede.org"

            # Automatically use c-base email when sending/replying to c-base addresses
            send-hook "." "unmy_hdr From"
            send-hook "~C .*@c-base\.org" "my_hdr From: lassulus@c-base.org"

            set sort=threads

            set index_format="%4C %Z %?GI?%GI& ? %[%y-%m-%d] %-20.20a %?M?(%3M)& ? %s %> %r %g"

            virtual-mailboxes "INBOX" "notmuch://?query=folder:\"\" AND NOT tag:archive"
            virtual-mailboxes "Unread" "notmuch://?query=tag:unread"
            source "${genVirtualMailboxes}|"
            virtual-mailboxes "TODO" "notmuch://?query=tag:TODO"
            virtual-mailboxes "Starred" "notmuch://?query=tag:*"
            virtual-mailboxes "Archive" "notmuch://?query=tag:archive"
            virtual-mailboxes "Sent" "notmuch://?query=tag:sent"
            virtual-mailboxes "Junk" "notmuch://?query=tag:junk"
            virtual-mailboxes "All" "notmuch://?query=*"

            # clan.lol IMAP - no mailboxes declaration to prevent any startup connection
            # Select the separator entry in sidebar, folder-hook will redirect to the IMAP server
            virtual-mailboxes "clan-infra" "notmuch://?query=tag:nonexistent-separator-tag"
            account-hook imaps://mail.clan.lol "set imap_user = 'infra@clan.lol'; set imap_pass = \"\`SOPS_AGE_KEY=\$(rbw get --folder clan.lol clan-infra --field age-key) nix develop git+https://git.clan.lol/clan/clan-infra -c clan vars get --flake git+https://git.clan.lol/clan/clan-infra web01 infra-mail/infra-password\`\""
            folder-hook "notmuch://\\?query=tag:nonexistent-separator-tag" "push '<change-folder>imaps://mail.clan.lol<enter>'"

            # dedede.org IMAP (Namecheap Private Email)
            virtual-mailboxes "dedede" "notmuch://?query=tag:nonexistent-dedede-tag"
            account-hook imaps://mail.privateemail.com "set imap_user = 'mail@dedede.org'; set imap_pass = \"\`rbw get --folder dedede mail@dedede.org\`\""
            folder-hook "notmuch://\\?query=tag:nonexistent-dedede-tag" "push '<change-folder>imaps://mail.privateemail.com<enter>'"

            tag-transforms "junk"     "k" \
                           "unread"   "u" \
                           "replied"  "↻" \
                           "TODO"     "T" \

            # notmuch bindings
            macro index \\\\ "<vfolder-from-query>"
            macro index + "<modify-labels>+*\n<sync-mailbox>"
            macro index - "<modify-labels>-*\n<sync-mailbox>"

            # muchsync
            bind index \Cr noop
            macro index \Cr \
            "<enter-command>unset wait_key<enter> \
            <sync-mailbox> \
            <shell-escape>${self.packages.${pkgs.system}.muchsync}/bin/muchsync -vv<enter> \
            <sync-mailbox>

            #killed
            bind index d noop
            bind pager d noop

            bind index S noop
            bind index s noop
            bind pager S noop
            bind pager s noop
            macro index S "<modify-labels-then-hide>-inbox -unread +junk\n"
            macro index s "<modify-labels>-junk\n"
            macro pager S "<modify-labels-then-hide>-inbox -unread +junk\n"
            macro pager s "<modify-labels>-junk\n"

            bind index A noop
            bind index a noop
            bind pager A noop
            bind pager a noop
            macro index A "<modify-labels>+archive -unread -inbox\n" "Archive message"
            macro pager A "<modify-labels>+archive -unread -inbox\n" "Archive message"

            bind index U noop
            bind index u noop
            bind pager U noop
            bind pager u noop
            macro index U "<modify-labels>+unread\n"
            macro index u "<modify-labels>-unread\n"
            macro pager U "<modify-labels>+unread\n"
            macro pager u "<modify-labels>-unread\n"

            bind index t noop
            bind pager t noop
            macro index t "<modify-labels>"

            # top index bar in email view
            set pager_index_lines=7
            # top_index_bar toggle
            macro pager ,@1 "<enter-command> set pager_index_lines=0; macro pager ] ,@2 'Toggle indexbar<Enter>"
            macro pager ,@2 "<enter-command> set pager_index_lines=3; macro pager ] ,@3 'Toggle indexbar<Enter>"
            macro pager ,@3 "<enter-command> set pager_index_lines=7; macro pager ] ,@1 'Toggle indexbar<Enter>"
            macro pager ] ,@1 'Toggle indexbar

            # scan urls from emails
            macro index,pager \cb "<pipe-message> ${lib.getExe pkgs.urlscan}<Enter>"
            macro attach,compose \cb "<pipe-entry> ${lib.getExe pkgs.urlscan}<Enter>"

            # view HTML in graphical browser
            macro index,pager H "<pipe-message>${viewHtmlBrowser}/bin/view-html-browser<Enter>" "View HTML in browser"

            # forward invoice to sevdesk
            send-hook "~t autobox@sevdesk.email" "my_hdr From: sevdesk@lassul.us"
            macro index,pager I "<forward-message>autobox@sevdesk.email<enter>" "Forward invoice to sevdesk"

            # sidebar
            set sidebar_divider_char = '│'
            set sidebar_delim_chars = "/"
            set sidebar_short_path
            set sidebar_folder_indent
            set sidebar_visible = yes
            set sidebar_format = '%D%?F? [%F]?%* %?N?%N/? %?S?%S?'
            set sidebar_width   = 30
            color sidebar_new yellow red

            # sidebar bindings
            bind index <left> sidebar-prev
            bind index <right> sidebar-next
            bind index <space> sidebar-open
            # sidebar toggle
            macro index,pager ,@) "<enter-command> set sidebar_visible=no; macro index,pager [ ,@( 'Toggle sidebar'<Enter>"
            macro index,pager ,@( "<enter-command> set sidebar_visible=yes; macro index,pager [ ,@) 'Toggle sidebar'<Enter>"
            macro index,pager [ ,@( 'Toggle sidebar'

            # forward with attachment
            set mime_forward = no
            set forward_attachments = yes

            # better handling of long URLs
            set wrap = 0  # don't wrap lines in the pager
            set markers = no  # don't show + markers for wrapped lines
            set smart_wrap = yes  # wrap at word boundaries when displaying
            set pager_stop = yes  # don't jump to next message at end of pager
          '';

        in
        (inputs.wrappers.lib.wrapPackage {
          pkgs = pkgs;
          package = pkgs.neomutt;
          aliases = [ "mutt" ];
          runtimeInputs = [
            elinks
            pkgs.msmtp
            pkgs.notmuch
            pkgs.openssh
            pkgs.urlscan
          ]
          ++ lib.optionals pkgs.stdenv.isLinux [
            pkgs.iputils
          ];
          env = {
            NOTMUCH_CONFIG = notmuchConfig;
          };
          flags = {
            "-F" = "${muttrc}";
          };
        }).overrideAttrs
          (old: {
            passthru = (old.passthru or { }) // {
              inherit msmtp;
            };
          });
    };
}
