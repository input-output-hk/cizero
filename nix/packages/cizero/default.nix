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

      zigDepHashes = {
        cron = "1ci56xsrkzdr2js5k3qsyb6pm2awslp481lif1c1mljg85swq351";
        datetime = "15skn6rhybxkjr0jcj866blpr4pdxp072n2nhcfgngcv52d3r46w";
        httpz = "0xq4ngd5brm9j2c0qclxammci0a1qls5hx7d374dlsjclrvkc5bb";
        known-folders = "0xhqs9mv9dp7pdcsrg1vi9i0kfaq1lrhr3zjy9kbpkh273xfg5vd";
      };

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';
    };
  };
}
