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
    packages.cizero = pkgs.buildZigPackage rec {
      src = inputs.inclusive.lib.inclusive ../../.. [
        ../../../src
        ../../../lib
      ];

      buildInputs = with pkgs; [
        wasmtime.dev
        sqlite.dev
        whereami
      ];

      zigDepsHash = "sha256-8pmGZh8xpqGH8gQ0sPuk2vwxdIV0uoK+6LGLB7rdMDg=";

      zigTarget = null;

      buildZigZon = "src/build.zig.zon";

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
