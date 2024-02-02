{inputs, ...}: {
  imports = [
    ./plugins/hello-zig.nix
    ./plugins/hello-crystal.nix
  ];

  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    packages.cizero = config.overlayAttrs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../../.. [
        ../../../build.zig
        ../../../build.zig.zon
        ../../../src
      ];

      nativeBuildInputs = with pkgs; [
        wasmtime.dev
        sqlite.dev
      ];

      zigDepsHash = "sha256-pml8GuVxHFFYNoryiuWU24N7ftEs33G74L/hGu3JQEU=";

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';

      passthru.pdkTests =
        lib.genAttrs
        (lib.pipe ../../../pdk [builtins.readDir builtins.attrNames])
        (pdk:
          config.packages.cizero.overrideAttrs (oldAttrs: {
            pname = "cizero-pdk-${pdk}";

            dontBuild = true;
            dontInstall = true;

            preCheck = ''
              ${oldAttrs.preCheck}

              # for temporary files written by cizero
              mkdir "''${XDG_CACHE_HOME:-$HOME/.cache}"
            '';

            checkPhase = ''
              runHook preCheck

              zig build test-pdk -Dplugin=${config.packages."cizero-plugin-hello-${pdk}"}/libexec/cizero/plugins/hello-${lib.escapeShellArg pdk}.wasm

              runHook postCheck
            '';

            postCheck = ''
              touch $out
            '';
          }));
    };
  };
}
