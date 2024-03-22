{
  imports = [
    ./cizero-pdk-zig.nix
    ./cizero-plugin-hydra-eval-jobs.nix
  ];

  perSystem = {
    config,
    lib,
    ...
  }: {
    checks =
      lib.mapAttrs'
      (k: v: lib.nameValuePair "cizero-pdk-${k}" (lib.mkDefault v))
      config.packages.cizero.passthru.pdkTests;
  };
}
