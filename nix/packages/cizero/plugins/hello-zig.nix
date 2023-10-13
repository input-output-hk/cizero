{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    final,
    ...
  }: {
    packages.cizero-plugin-hello-zig = final.buildZigPackage rec {
      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/hello-zig
        ../../../../pdk/zig
      ];

      inherit (config.packages) zig;

      buildZigZon = "${src}/plugins/hello-zig/build.zig.zon";

      buildInputs = with pkgs; [
        wasmtime # for tests
      ];

      preBuild = ''
        cd plugins/hello-zig
      '';

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';
    };
  };
}
