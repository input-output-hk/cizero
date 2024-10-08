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
        ../../../../lib
      ];

      buildZigZon = "plugins/hydra-eval-jobs/build.zig.zon";

      zigDepsHash = "sha256-RZ2e02HBVvIYdqwG1JMrAnhhndYmr04I88hYAZpB38E=";

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
          ../../../../lib
        ];

        buildZigZon = "plugins/hydra-eval-jobs/hydra-eval-jobs/build.zig.zon";

        zigDepsHash = "sha256-iuniM64D/SEUe00/7dKKfUGPTGE3WNCiGrQN2EX3ZfI=";

        meta.mainProgram = "hydra-eval-jobs";
      };
    };
  };
}
