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
        ../../src/lib.zig
        ../../src/lib
      ];

      buildZigZon = "pdk/zig/build.zig.zon";

      zigDepsHash = "sha256-pml8GuVxHFFYNoryiuWU24N7ftEs33G74L/hGu3JQEU=";

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
