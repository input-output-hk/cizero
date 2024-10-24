{inputs, ...}: {
  imports = with inputs; [
    mission-control.flakeModule
    flake-root.flakeModule
    make-shell.flakeModules.default
  ];

  perSystem = {
    inputs',
    config,
    lib,
    pkgs,
    ...
  }: rec {
    devShells.default = config.make-shells.cizero.finalPackage;

    make-shell.imports = [
      ({name, ...}: {
        name = "devShell-${name}";

        inputsFrom = [
          config.mission-control.devShell
          config.flake-root.devShell
        ];
      })
    ];

    make-shells = {
      zig = {
        packages = with pkgs; [zls];

        shellHook = ''
          # TODO remove once merged: https://github.com/NixOS/nixpkgs/pull/310588
          # Set to `/build/tmp.XXXXXXXXXX` by the zig hook.
          unset ZIG_GLOBAL_CACHE_DIR

          export ZIG_LOCAL_CACHE_DIR="$FLAKE_ROOT/.zig-cache"
        '';
      };

      wasm = {
        packages = with pkgs; [wasm-tools];

        env.WASMTIME_BACKTRACE_DETAILS = 1;
      };

      cizero = {
        imports = with make-shells; [
          zig
          wasm
        ];

        packages = [
          inputs'.nix.packages.nix
          inputs'.nix-sigstop.packages.default
        ];

        inputsFrom = [
          config.packages.cizero
        ];
      };

      "cizero/crystal" = {
        imports = with make-shells; [cizero];

        packages = with pkgs; [crystal crystalline];
      };
    };

    mission-control = {
      wrapperName = "just";
      scripts = let
        # just to make sure the script exists
        just = script: assert config.mission-control.scripts ? ${script}; script;

        prelude = ''
          function try {
            local stdout stderrFile status
            trap 'rm --force "$stderrFile"' RETURN
            stderrFile=$(mktemp)

            if stdout=$("$@" 2>"$stderrFile"); then
              printf '%s' "$stdout"
            else
              status=$?
              cat >&2 "$stderrFile"
              return $status
            fi
          }
        '';

        releaseFlag = ''
          if [[ "''${1:-}" = --release ]]; then
            releaseFlag=true
            shift
          fi
        '';

        zigBuildFlags = lib.escapeShellArgs [
          "-freference-trace"
          "--color"
          "on"
        ];
      in {
        run = {
          description = "run cizero without any plugins";
          exec = ''
            ${prelude}

            exec zig build ${zigBuildFlags} run -- "$@"
          '';
        };

        run-plugin = {
          description = "run cizero with a certain plugin";
          exec = ''
            ${prelude}

            ${releaseFlag}

            plugin="$1"
            shift

            result=$(try ${just "build-plugin"} ''${releaseFlag:+--release} "$plugin")

            set -x
            exec zig build ${zigBuildFlags} run -- "$result"/libexec/cizero/plugins/* "$@"
          '';
        };

        run-plugins = {
          description = "run cizero with all plugins";
          exec = ''
            ${prelude}

            ${releaseFlag}

            plugins_unsplit=$(try ${just "build-plugins"} ''${releaseFlag:+--release})
            readarray -t plugins <<<"$plugins_unsplit"
            set -x
            exec zig build ${zigBuildFlags} run -- "''${plugins[@]}" "$@"
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

        build-plugin = {
          category = "Packages → Plugins";
          description = "build a plugin";
          exec = ''
            ${prelude}

            ${releaseFlag}

            plugin="$1"
            shift

            if [[ -v releaseFlag ]]; then
              exec nix build --no-link --print-build-logs --print-out-paths .#cizero-plugin-"$plugin" "$@"
            else
              pushd >/dev/null plugins/"$plugin"
              case "$plugin" in
                hello-zig | hydra-eval-jobs)
                  try nix develop --command zig build ${zigBuildFlags} "$@" 1>/dev/null
                  realpath zig-out
                  ;;
                *)
                  echo >&2 "I don't know how to build the plugin \"$plugin\" without \`--release\` (as first argument)."
                  exit 1
                  ;;
              esac
              popd >/dev/null
            fi
          '';
        };

        build-plugins = {
          category = "Packages → Plugins";
          description = "build all plugins";
          exec = lib.pipe config.packages [
            builtins.attrNames
            (builtins.filter (lib.hasPrefix "cizero-plugin-"))
            (map (lib.removePrefix "cizero-plugin-"))
            (ks: ''
              ${releaseFlag}

              for plugin in ${lib.escapeShellArgs ks}; do
                ${just "build-plugin"} ''${releaseFlag:+--release} "$plugin" "$@"
              done
            '')
          ];
        };

        test-pdk = {
          description = "test the PDK of a certain language";
          exec = ''
            ${prelude}

            ${releaseFlag}

            language="$1"
            shift

            result=$(try ${just "build-plugin"} ''${releaseFlag:+--release} hello-"$language")

            set -x
            exec zig build ${zigBuildFlags} test-pdk --summary all -Dplugin="$(echo "$result"/libexec/cizero/plugins/*)" "$@"
          '';
        };
      };
    };
  };
}
