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

      zigDepsHash = "sha256-rzHnTbptiaC1cGr+5pL6+l/UMZuQDkX4BB0UTk/NL0U=";

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
