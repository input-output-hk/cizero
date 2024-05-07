{inputs, ...}: {
  imports = [
    plugins/hello-zig.nix
    plugins/hello-crystal.nix
    plugins/hydra-eval-jobs.nix
  ];

  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    packages.cizero = pkgs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../../.. [
        ../../../build.zig
        ../../../build.zig.zon
        ../../../src
      ];

      buildInputs = with pkgs; [
        wasmtime.dev
        sqlite.dev
        whereami
      ];

      zigDepsHash = "sha256-wsCEw5wvFeLfAnLD4+wiebwR7t5VsWO06O+o4Ef5RYs=";

      zigTarget = null;

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

            zigRelease = false;

            preCheck = ''
              ${oldAttrs.preCheck}

              # for temporary files written by cizero
              mkdir "''${XDG_CACHE_HOME:-$HOME/.cache}"
            '';

            checkPhase = ''
              runHook preCheck

              local flagsArray=(
                  "''${zigDefaultFlagsArray[@]}"
                  $zigCheckFlags "''${zigCheckFlagsArray[@]}"
              )

              zig build test-pdk \
                "''${flagsArray[@]}" \
                -Dplugin=${config.packages."cizero-plugin-hello-${pdk}"}/libexec/cizero/plugins/hello-${lib.escapeShellArg pdk}.wasm

              runHook postCheck
            '';

            postCheck = ''
              touch $out
            '';
          }));
    };
  };
}
