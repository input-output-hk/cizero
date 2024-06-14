{inputs, ...}: {
  imports = with inputs; [
    mission-control.flakeModule
    flake-root.flakeModule
  ];

  perSystem = {
    config,
    inputs',
    lib,
    pkgs,
    ...
  }: {
    devShells = {
      default = pkgs.mkShell {
        name = "devShell";
        packages = with pkgs; [
          zls
          wasm-tools
        ];
        inputsFrom = [
          config.mission-control.devShell
          config.packages.cizero
        ];

        env.WASMTIME_BACKTRACE_DETAILS = 1;

        # TODO remove once merged: https://github.com/NixOS/nixpkgs/pull/310588
        shellHook = ''
          # Set to `/build/tmp.XXXXXXXXXX` by the zig hook.
          unset ZIG_GLOBAL_CACHE_DIR
        '';
      };

      crystal = pkgs.mkShell {
        name = "${config.devShells.default.name}-crystal";
        packages = with pkgs; [crystal crystalline];
        inputsFrom = [config.devShells.default];
      };

      haskell = pkgs.mkShell {
        name="${config.devShells.default.name}-haskell";
        packages = with pkgs; [ inputs'.ghc-wasm-meta.packages.wasm32-wasi-ghc-gmp  ];
        inputsFrom = [config.devShells.default];
      };
    };

    mission-control = {
      wrapperName = "just";
      scripts = rec {
        run = {
          description = "run cizero without any plugins";
          exec = ''
            zig build run -- "$@"
          '';
        };

        run-plugin = {
          description = "run cizero with a certain plugin";
          exec = ''
            result=$(nix build .#cizero-plugin-"$1" --no-link --print-build-logs --print-out-paths)
            shift
            set -x
            zig build run -- "$result"/libexec/cizero/plugins/* "$@"
          '';
        };

        run-plugins = {
          description = "run cizero with all plugins";
          exec = ''
            #shellcheck disable=SC2016
            plugins_unsplit=$($BASH <<<${lib.escapeShellArg build-plugins.exec})
            readarray -t plugins <<<"$plugins_unsplit"
            set -x
            zig build run -- "''${plugins[@]}" "$@"
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
              nix build --no-link --print-build-logs --print-out-paths "''${attrs[@]}" "$@"
            '')
          ];
        };

        test-pdk = {
          description = "test the PDK of a certain language";
          exec = ''
            result=$(nix build .#cizero-plugin-hello-"$1" --no-link --print-build-logs --print-out-paths)
            shift
            set -x
            zig build test-pdk --summary all -Dplugin="$(echo "$result"/libexec/cizero/plugins/*)" "$@"
          '';
        };
      };
    };
  };
}
