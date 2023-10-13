{ inputs, ... }: {
  perSystem = { config, pkgs, ... }: {
    devShells = {
      default = pkgs.mkShell {
        packages = [ config.packages.zls ];
        inputsFrom = [ config.packages.cizero ];
      };

      crystal = pkgs.mkShell {
        packages = with pkgs; [ crystal crystalline ];
      };
    };
  };
}
