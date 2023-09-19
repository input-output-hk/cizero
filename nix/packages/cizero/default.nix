{ inputs, ... }: {
  imports = [
    ./plugins/foo.nix
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

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';
    };
  };
}
