{ inputs, ... }: {
  imports = with inputs; [
    mission-control.flakeModule
    flake-root.flakeModule
  ];

  perSystem = { config, lib, pkgs, ... }: {
    devShells = {
      default = pkgs.mkShell {
        packages = [ config.packages.zls ];
        inputsFrom = [
          config.mission-control.devShell
          config.packages.cizero
        ];
      };

      crystal = pkgs.mkShell {
        packages = with pkgs; [ crystal crystalline ];
        inputsFrom = [ config.mission-control.devShell ];
      };
    };

    mission-control = {
      wrapperName = "just";
      scripts = {
        run = {
          description = "run cizero without any plugins";
          exec = ''
            nix run .#cizero
          '';
        };

        run-plugins = {
          description = "run cizero with all plugins";
          exec = ''
            result=$(nix build --no-link --print-out-paths)
            set -x
            "$result"/bin/cizero "$result"/libexec/cizero/plugins/*
          '';
        };

        list = {
          description = "see available packages";
          exec = lib.concatMapStrings (p: ''
            printf '%s\n' ${lib.escapeShellArg p}
          '') (builtins.attrNames config.packages);
        };
      };
    };
  };
}
