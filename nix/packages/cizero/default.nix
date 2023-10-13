{inputs, ...}: {
  imports = [
    ./plugins/hello-zig.nix
    ./plugins/hello-crystal.nix
  ];

  perSystem = {
    config,
    lib,
    pkgs,
    final,
    ...
  }: {
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

      zigBuildArgs = ["-Doptimize=ReleaseSafe"];

      zigDepHashes = {
        cron = "1ci56xsrkzdr2js5k3qsyb6pm2awslp481lif1c1mljg85swq351";
        datetime = "15skn6rhybxkjr0jcj866blpr4pdxp072n2nhcfgngcv52d3r46w";
        httpz = "0ndlvysij7l5djlypxxvqzz65y8n8kqd41bgnr0k6wp8q6mli3l4";
      };

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';
    };
  };
}
