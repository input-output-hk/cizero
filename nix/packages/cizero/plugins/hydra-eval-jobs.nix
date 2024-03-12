{inputs, ...}: {
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    packages.cizero-plugin-hydra-eval-jobs = config.overlayAttrs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/hydra-eval-jobs
        ../../../../pdk/zig
        ../../../../build.zig
        ../../../../build.zig.zon
        ../../../../src
      ];

      buildZigZon = "plugins/hydra-eval-jobs/build.zig.zon";

      zigDepsHash = "sha256-I7ImYz7MMk8nLHW+ONWc+mOr8WsX3ui7uV1JjS+j1rQ=";

      nativeCheckInputs = with pkgs; [
        wasmtime
      ];

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';

      passthru = rec {
        hydra-eval-jobs = config.overlayAttrs.buildZigPackage {
          src = inputs.inclusive.lib.inclusive ../../../.. [
            ../../../../plugins/hydra-eval-jobs
          ];

          buildZigZon = "plugins/hydra-eval-jobs/hydra-eval-jobs/build.zig.zon";

          zigDepsHash = "sha256-Ftvvp2X7mkjboMTUbQ+/oPW2AEmmcq7uZlHa2KiZSo4=";

          meta.mainProgram = "hydra-eval-jobs";
        };

        hydra-unstable = pkgs.hydra-unstable.overrideAttrs (oldAttrs: {
          postInstall = ''
            ${oldAttrs.postInstall}
            ln --symbolic --force ${lib.getExe hydra-eval-jobs} $out/bin/hydra-eval-jobs
          '';
        });
      };
    };
  };
}
