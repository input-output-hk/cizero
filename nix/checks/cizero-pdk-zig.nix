{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    checks.cizero-pdk-zig = config.overlayAttrs.buildZigPackage rec {
      src = inputs.inclusive.lib.inclusive ../.. [
        ../../pdk/zig
      ];

      buildZigZon = "pdk/zig/build.zig.zon";

      zigDepsHash = "sha256-UabUML+ClU8CUFYf731C2zG0SLHIPHNrDbMobP+Dm8Y=";

      nativeCheckInputs = with pkgs; [
        wasmtime
      ];

      dontBuild = true;

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
