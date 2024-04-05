parts @ {inputs, ...}: {
  perSystem = perSystem @ {
    system,
    pkgs,
    ...
  }: {
    checks.cizero-plugin-hydra-eval-jobs = inputs.nixpkgs.lib.nixos.runTest ({nodes, ...}: let
      hydraUser = {
        name = "admin";
        password = "admin";
      };
    in {
      name = "cizero-plugin-hydra-eval-jobs";

      hostPkgs = pkgs;

      nodes.machine = {
        config,
        pkgs,
        ...
      }: {
        imports = [parts.config.flake.nixosModules.cizero];

        nixpkgs.overlays = [parts.config.flake.overlays.cizero-plugin-hydra-eval-jobs];

        environment.systemPackages =
          [
            (pkgs.writeShellApplication {
              name = "create-trivial-project.sh";
              runtimeInputs = with pkgs; [curl];
              text = let
                flake = pkgs.writeTextDir "flake.nix" ''
                  {
                    outputs = _: {
                      hydraJobs.trivial = builtins.derivation {
                        name = "trivial";
                        system = "${system}";
                        builder = "/bin/sh";
                        allowSubstitutes = false;
                        preferLocalBuild = true;
                        args = ["-c" "echo success > $out; exit 0"];
                      };
                    };
                  }
                '';
              in ''
                URL=http://localhost:${toString config.services.hydra.port}
                PROJECT_NAME=trivial
                JOBSET_NAME=trivial

                mycurl() {
                  curl \
                    --silent \
                    --fail-with-body \
                    --referer "$URL" \
                    --header 'Accept: application/json' \
                    --header 'Content-Type: application/json' \
                    "$@"
                }

                cat >data.json <<EOF
                { "username": "${hydraUser.name}", "password": "${hydraUser.password}" }
                EOF
                mycurl --request POST "$URL/login" --data @data.json --cookie-jar cookies.txt

                cat >data.json <<EOF
                {
                  "displayname":"Trivial",
                  "enabled":"1",
                  "visible":"1"
                }
                EOF
                mycurl --request PUT "$URL/project/$PROJECT_NAME" --data @data.json --cookie cookies.txt

                cat >data.json <<EOF
                {
                  "enabled": 2,
                  "type": 1,
                  "flake": "path:${flake}",
                  "visible": true,
                  "checkinterval": 60,
                  "keepnr": "1",
                  "enableemail": false
                }
                EOF
                mycurl --request PUT "$URL/jobset/$PROJECT_NAME/$JOBSET_NAME" --data @data.json --cookie cookies.txt
              '';
            })
          ]
          ++ (with pkgs; [
            jq
          ]);

        nix.settings.experimental-features = ["nix-command" "flakes"];

        services = {
          cizero = {
            enable = true;
            plugins = [
              perSystem.config.packages.cizero-plugin-hydra-eval-jobs
            ];
          };

          hydra = {
            enable = true;
            hydraURL = "http://example.com";
            notificationSender = "hydra@example.com";
          };
        };
      };

      testScript = ''
        machine.wait_for_unit("cizero.service")
        machine.wait_for_open_port(${toString nodes.machine.services.cizero.httpPort})

        machine.wait_for_unit("hydra-server.service")
        machine.wait_for_open_port(${toString nodes.machine.services.hydra.port})

        machine.succeed("hydra-create-user admin --role ${hydraUser.name} --password ${hydraUser.password}")
        machine.succeed("create-trivial-project.sh")

        machine.wait_until_succeeds(
          'curl --silent --location http://localhost:${toString nodes.machine.services.hydra.port}/build/1 --header "Accept: application/json"' +
          ' | jq .buildstatus' +
          ' | xargs test 0 -eq'
        )
      '';
    });
  };
}
