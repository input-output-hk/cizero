{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    packages.cizero-plugin-hello-zig = config.overlayAttrs.buildZigPackage rec {
      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/hello-zig
        ../../../../pdk/zig
        ../../../../build.zig
        ../../../../build.zig.zon
        ../../../../src
      ];

      buildZigZon = "plugins/hello-zig/build.zig.zon";

      zigDepsHash = "sha256-myvS5kwxDJ+xCanvudG7h3JwEq7GyqPHudoIjF5yQaI=";

      nativeCheckInputs = with pkgs; [
        wasmtime
      ];

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';
    };
  };
}
