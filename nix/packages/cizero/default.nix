{ inputs, ... }: {
  imports = [
    ./plugins/foo.nix
    ./plugins/hello.nix
  ];

  perSystem = { config, lib, pkgs, final, ... }: {
    packages.cizero = final.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../../.. [
        ../../../build.zig
        ../../../build.zig.zon
        ../../../src
      ];

      inherit (config.packages) zig;

      buildInputs = with pkgs; [
        wasmtime.dev
        wasmtime # for tests
      ];

      zigBuildArgs = [ "-Doptimize=ReleaseSafe" ];

      zigDepHashes = {
        cron = "1ci56xsrkzdr2js5k3qsyb6pm2awslp481lif1c1mljg85swq351";
        datetime = "15skn6rhybxkjr0jcj866blpr4pdxp072n2nhcfgngcv52d3r46w";
      };

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';
    };
  };
}
