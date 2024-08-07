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

      zigDepsHash = "sha256-wnva5TJsPrzVfTJFsD+zkZcGiTvZ++Zqk8C/f2idf/w=";

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

        zigDepsHash = "sha256-15bcToU57WBfCbDpEFHh0jRM3yyjipFNe9rs/Nz4raM=";

        meta.mainProgram = "hydra-eval-jobs";
      };
    };
  };
}
