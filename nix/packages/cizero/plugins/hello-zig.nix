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
        ../../../../src/lib.zig
        ../../../../src/lib
      ];

      buildZigZon = "plugins/hello-zig/build.zig.zon";

      zigDepsHash = "sha256-TcaOcUzNfsT4txPXKMfmZFhCwkdST1g3QXQQFCeyprk=";

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
