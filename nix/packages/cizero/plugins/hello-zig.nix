{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    packages.cizero-plugin-hello-zig = config.overlayAttrs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/hello-zig
        ../../../../pdk/zig
        ../../../../build.zig
        ../../../../build.zig.zon
        ../../../../src
      ];

      buildZigZon = "plugins/hello-zig/build.zig.zon";

      zigDepsHash = "sha256-BLc8+ENOUVr1wTNeh3iW1x0FwsC+DlEKe2kFMopo9YM=";

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
