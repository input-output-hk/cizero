{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    checks.cizero-pdk-zig = pkgs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../.. [
        ../../pdk/zig
        ../../build.zig
        ../../build.zig.zon
        ../../src
      ];

      buildZigZon = "pdk/zig/build.zig.zon";

      zigDepsHash = "sha256-I7ImYz7MMk8nLHW+ONWc+mOr8WsX3ui7uV1JjS+j1rQ=";

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
