{inputs, ...}: {
  imports = with inputs; [
    mission-control.flakeModule
    flake-root.flakeModule
  ];

  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    devShells = {
      default = pkgs.mkShell {
        packages = [config.packages.zls];
        inputsFrom = [
          config.mission-control.devShell
          config.packages.cizero
        ];
      };

      crystal = pkgs.mkShell {
        packages = with pkgs; [config.packages.zls config.packages.cizero crystal crystalline watchexec];
        inputsFrom = [config.mission-control.devShell];
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
          category = "Packages";
          description = "see available packages";
          exec =
            ''
              tput bold
              echo -n 'Packages available for ' >&2
              tput setaf 4 # blue
              echo -n 'nix build .#' >&2
              tput setaf 5 # magenta
              #shellcheck disable=SC2016
              echo -n '$PACKAGE' >&2
              tput sgr0 # reset
              tput bold
              echo : >&2
              tput sgr0 # reset
            ''
            + lib.concatMapStrings (p: ''
              printf '%s\n' ${lib.escapeShellArg p}
            '') (builtins.attrNames config.packages);
        };

        build-plugins = {
          category = "Packages → Plugins";
          description = "build all plugins";
          exec = lib.pipe config.packages [
            builtins.attrNames
            (builtins.filter (lib.hasPrefix "cizero-plugin-"))
            (ks: ''
              declare -a attrs
              for attr in ${lib.escapeShellArgs ks}; do
                  attrs+=(".#$attr")
              done
              nix build --no-link --print-out-paths "''${attrs[@]}"
            '')
          ];
        };
      };
    };
  };
}
