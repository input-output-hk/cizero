{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    final,
    ...
  }: {
    packages.cizero-plugin-foo = final.buildZigPackage rec {
      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/foo
        ../../../../pdk/zig
      ];

      inherit (config.packages) zig;

      buildZigZon = "${src}/plugins/foo/build.zig.zon";

      buildInputs = with pkgs; [
        wasmtime # for tests
      ];

      preBuild = ''
        cd plugins/foo
      '';

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';
    };
  };
}
