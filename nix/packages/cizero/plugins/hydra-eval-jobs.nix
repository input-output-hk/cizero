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

      zigDepsHash = "sha256-ywiGyOnJBhOFYiqLIH+dpIMf9JG9TdvCeT0VVxzHCRI=";

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

        zigDepsHash = "sha256-Ccxm64HiUdSUOUWHqMAY+VdbxyOGPT5cSbYFC4FfxTE=";

        meta.mainProgram = "hydra-eval-jobs";
      };
    };
  };
}
