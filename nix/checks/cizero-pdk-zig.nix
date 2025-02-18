{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    checks.cizero-pdk-zig = pkgs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../.. [
        ../../pdk/zig
        ../../src
      ];

      buildZigZon = "pdk/zig/build.zig.zon";

      zigDepsHash = "sha256-t/XhzMoXtgkh8jnKqFLPieY1Zrxuf6XnaI8hFymU28g=";

      zigTarget = null;

      nativeCheckInputs = with pkgs; [
        wasmtime
      ];

      propagatedCheckInputs = [
        config.packages.cizero.passthru.pdkTests.zig
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
