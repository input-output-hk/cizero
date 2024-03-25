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

      zigDepsHash = "sha256-I7ImYz7MMk8nLHW+ONWc+mOr8WsX3ui7uV1JjS+j1rQ=";

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
