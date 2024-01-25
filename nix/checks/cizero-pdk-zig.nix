{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    checks.cizero-pdk-zig = config.overlayAttrs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../.. [
        ../../pdk/zig
        ../../build.zig
        ../../build.zig.zon
        ../../src
      ];

      buildZigZon = "pdk/zig/build.zig.zon";

      zigDepsHash = "sha256-myvS5kwxDJ+xCanvudG7h3JwEq7GyqPHudoIjF5yQaI=";

      nativeCheckInputs = with pkgs; [
        wasmtime
      ];

      dontBuild = true;
      dontInstall = true;

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';

      postCheck = ''
        touch $out
      '';
    };
  };
}
