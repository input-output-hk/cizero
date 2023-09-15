{ inputs, ... }: {
  perSystem = { config, lib, pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = [
        config.packages.zls
        pkgs.extism-cli
        pkgs.wasmtime
      ];
      inputsFrom = [ config.packages.default ];

      shellHook = ''
        cd "$(git rev-parse --show-toplevel)"

        mkdir -p vendor

        ln -s ${inputs.extism} vendor/extism
      '';
    };
  };
}
