# Package overrides for the phone massulus (droidNixConfigurations.massulus),
# to keep its closure small. CI builds the overridden packages on aarch64.
_final: prev: {
  # icu4c (40 MiB) only came in via nix's boost
  boost189 = prev.boost189.override { enableIcu = false; };

  # aws-crt-cpp and the aws-c-* libraries (8 MiB) are only for s3:// stores
  nix = prev.nix.overrideScope (
    _: scope: { nix-store = scope.nix-store.override { withAWS = false; }; }
  );

}
