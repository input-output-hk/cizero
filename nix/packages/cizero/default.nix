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
        whereami
      ];

      zigDepsHash = "sha256-v1FasDL2KOI2JXBYl3XThntVujqHmL7YyzroMTL+oxQ=";

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
