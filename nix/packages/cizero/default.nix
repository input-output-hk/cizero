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
      src = ../../../src;

      buildInputs = with pkgs; [
        wasmtime.dev
        sqlite.dev
        whereami
      ];

      zigDepsHash = "sha256-VlsOuS9Dfcyuq6O5olieQVdT2Qh+O86pBb0jwUq0cIs=";

      zigTarget = null;

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
                ../../../pdk/zig
              ];

              buildZigZon = "build.zig.zon";

              zigDepsHash = "sha256-rzHnTbptiaC1cGr+5pL6+l/UMZuQDkX4BB0UTk/NL0U=";

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
