{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    final,
    ...
  }: {
    checks.cizero-pdk-zig = final.buildZigPackage rec {
      src = inputs.inclusive.lib.inclusive ../.. [
        ../../pdk/zig
      ];

      inherit (config.packages) zig;

      buildZigZon = "${src}/pdk/zig/build.zig.zon";

      buildInputs = with pkgs; [
        wasmtime # for tests
      ];

      dontBuild = true;

      preCheck = ''
        cd pdk/zig

        # for wasmtime cache
        export HOME="$TMPDIR"
      '';

      postCheck = ''
        touch $out
      '';
    };
  };
}
