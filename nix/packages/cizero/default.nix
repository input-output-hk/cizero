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
        ../../../src
        ../../../lib
      ];

      buildInputs = with pkgs; [
        wasmtime.dev
        sqlite.dev
        whereami
      ];

      zigDepsHash = "sha256-9oScZC7w8r1TNodXPotkx+f7ssH4ija5DOFxENSWyzs=";

      zigTarget = null;

      buildZigZon = "src/build.zig.zon";

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';

      passthru.pdkTests =
        lib.genAttrs
        (lib.pipe ../../../pdk [builtins.readDir builtins.attrNames])
        (
          pdk:
            (config.packages.cizero.override {
              pname = "cizero-pdk-${pdk}";

              src = inputs.inclusive.lib.inclusive ../../.. [
                ../../../build.zig
                ../../../build.zig.zon
                ../../../pdk-test.zig
                ../../../src
                ../../../lib
                ../../../pdk/zig
                ../../../nix-sigstop
              ];

              buildZigZon = "build.zig.zon";

              zigDepsHash = "sha256-RZ2e02HBVvIYdqwG1JMrAnhhndYmr04I88hYAZpB38E=";

              zigRelease = "Debug";
            })
            .overrideAttrs (oldAttrs: {
              dontBuild = true;
              dontInstall = true;

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
            })
        );
    };
  };
}
