{inputs, ...}: {
  perSystem = {
    lib,
    pkgs,
    ...
  }: {
    packages.cizero-plugin-hydra-eval-jobs = pkgs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/hydra-eval-jobs
        ../../../../pdk/zig
        ../../../../src
      ];

      buildZigZon = "plugins/hydra-eval-jobs/build.zig.zon";

      zigDepsHash = "sha256-t/XhzMoXtgkh8jnKqFLPieY1Zrxuf6XnaI8hFymU28g=";

      zigTarget = null;

      nativeCheckInputs = with pkgs; [
        wasmtime
      ];

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';

      passthru.hydra-eval-jobs = pkgs.buildZigPackage {
        src = inputs.inclusive.lib.inclusive ../../../.. [
          ../../../../plugins/hydra-eval-jobs
        ];

        buildZigZon = "plugins/hydra-eval-jobs/hydra-eval-jobs/build.zig.zon";

        zigDepsHash = "sha256-/vi7EWzE55u5tJbEc2gVGPLkVX4AmiAtVcpBkl8dDnk=";

        meta.mainProgram = "hydra-eval-jobs";
      };
    };
  };
}
