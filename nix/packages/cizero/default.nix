{inputs, ...}: {
  imports = [
    ./plugins/hello-zig.nix
    ./plugins/hello-crystal.nix
  ];

  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    packages.cizero = config.overlayAttrs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../../.. [
        ../../../build.zig
        ../../../build.zig.zon
        ../../../src
      ];

      nativeBuildInputs = with pkgs; [
        wasmtime.dev
      ];

      nativeCheckInputs = with pkgs; [
        wasmtime
      ];

      zigDepsHash = "sha256-myvS5kwxDJ+xCanvudG7h3JwEq7GyqPHudoIjF5yQaI=";

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';
    };
  };
}
