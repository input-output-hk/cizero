{
  config,
  moduleWithSystem,
  ...
}: {
  flake.nixosModules = {
    default = config.flake.nixosModules.cizero;

    cizero = moduleWithSystem (perSystem @ {config}: {
      config,
      lib,
      pkgs,
      ...
    }: {
      options.services.cizero = {
        enable = lib.mkEnableOption "cizero";

        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.cizero or perSystem.config.packages.cizero;
        };

        plugins = lib.mkOption {
          type = with lib.types; listOf package;
          default = [];
        };

        httpAddress = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          readOnly = true;
        };

        httpPort = lib.mkOption {
          type = lib.types.port;
          default = 5882;
          readOnly = true;
        };
      };

      config = let
        cfg = config.services.cizero;
      in
        lib.mkIf cfg.enable {
          systemd.services.cizero = {
            wantedBy = ["multi-user.target"];
            after = ["network.target"];

            serviceConfig = {
              DynamicUser = true;
              StateDirectory = "cizero";
              CacheDirectory = "cizero";
            };

            path = [
              cfg.package
              config.nix.package
            ];
            script = ''
              export XDG_DATA_HOME=$STATE_DIRECTORY
              export XDG_CACHE_HOME=$CACHE_DIRECTORY

              exec cizero ${toString (
                map
                (plugin: "${plugin}/libexec/cizero/plugins/*.wasm")
                cfg.plugins
              )} "$@"
            '';
          };
        };
    });
  };
}
