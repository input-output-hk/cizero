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

      zigDepsHash = "sha256-jvvYDZ8l3Km8C3lZgvqiMFv89JoUQjorsa3RZhd3MbI=";

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
