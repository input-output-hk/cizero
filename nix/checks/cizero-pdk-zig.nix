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

      zigDepsHash = "sha256-BLc8+ENOUVr1wTNeh3iW1x0FwsC+DlEKe2kFMopo9YM=";

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
