{ inputs, ... }: {
  imports = [
    inputs.parts.flakeModules.easyOverlay
    packages/zig-package-info
  ];

  perSystem = { inputs', config, lib, pkgs, final, ... }: {
    packages = {
      default = config.packages.cizero;

      cizero = final.buildZigPackage {
        src = inputs.inclusive.lib.inclusive ./.. [
          ../build.zig
          ../build.zig.zon
          ../src
        ];

        inherit (config.packages) zig;

        buildInputs = with pkgs; [ wasmtime.dev ];

        zigBuildArgs = [ "-Doptimize=ReleaseSafe" ];

        zigDepHashes.tres = "1109s1iz3laar23csfgk3m9l5zqjqgb8mh41j976j1k6gbp0f46a";
      };

      zig = (pkgs.zig.overrideAttrs (oldAttrs: rec {
        version = src.rev;

        src = pkgs.fetchFromGitHub {
          inherit (oldAttrs.src) owner repo;
          rev = "402468b2109929779fc0fb59eeb5481cfb5ed44d";
          hash = "sha256-ZzHKXONvM1/gESWZEAdkLQZjgX0QZMwI6BranTVuY3k=";
        };

        patches = [];

        # do not build docs to avoid `error: too many arguments`
        outputs = [ "out" ];
        postBuild = "";
        postInstall = "";
      })).override {
        llvmPackages = pkgs.llvmPackages_16;
      };

      zls = final.buildZigPackage rec {
        src = pkgs.fetchFromGitHub {
          owner = "zigtools";
          repo = "zls";
          rev = "7aeb758e9e652c3bad8fd11d1fb146328a3edbd3";
          hash = "sha256-4NZ95T5wWi3kPofW6yHXd6aR0yZyVXPZUlv9Zzj/Fgs=";
          fetchSubmodules = true;
        };

        zigDepHashes = {
          binned_allocator = "0p2sx66fl2in3y80i14wvx6rfyfhrh5n7y88j35nl6x497i2pycv";
          diffz = "1r8ddmsy669mj3fxlmzvmhaf263a06q9j2hwjld3vgcylnimh9yw";
          known_folders = "1w8qiixcym2w0gqq58nqwqz53w6ylmr3awmi562w1axbarnpiy2k";
        };

        zigBuildArgs = [
          "-Dcpu=baseline"
          "-Doptimize=ReleaseSafe"
          "-Dversion_data_path=${passthru.langref}"
        ];

        # tests fail on master
        doCheck = false;

        passthru.langref = builtins.fetchurl {
          url = "https://raw.githubusercontent.com/ziglang/zig/${config.packages.zig.src.rev}/doc/langref.html.in";
          sha256 = "1x7h71kkg22gjddfk9kfbf69iys6r95klhv41xicnhvbssmhfbhc";
        };

        inherit (pkgs.zls) meta;
      };
    };

    overlayAttrs = {
      buildZigPackage = args @ {
        zig ? config.packages.zig,
        zigBuildArgs ? [],
        buildZigZon ? "build.zig.zon",
        zigDepHashes ? {},
        ...
      }: pkgs.stdenv.mkDerivation (finalAttrs: let
        zigArgs = toString (lib.cli.toGNUCommandLine {} {
          global-cache-dir = "$TMPDIR";
          prefix = "$out";
        } ++ zigBuildArgs);

        info = lib.importJSON finalAttrs.passthru.packageInfo;
      in
        {
          pname = info.name;
          inherit (info) version;

          postUnpack = lib.optionalString (finalAttrs.passthru ? deps) ''
            ln -s ${finalAttrs.passthru.deps} $TMPDIR/p
          '';

          buildPhase = ''
            zig build ${zigArgs}
          '';

          doCheck = true;
          checkPhase = ''
            zig build test ${zigArgs}
          '';

          dontInstall = true;
        } // builtins.removeAttrs args [
          "zig" "zigBuildArgs" "buildZigZon" "zigDepHashes"
        ] // {
          nativeBuildInputs = args.nativeBuildInputs or [] ++ [ zig ];

          passthru = {
            packageInfo = config.overlayAttrs.zigPackageInfo "${finalAttrs.src}/${buildZigZon}";

            # builds the global-cache-dir/p directory
            deps = pkgs.symlinkJoin {
              name = with finalAttrs; "${pname}-${version}-deps";
              paths = lib.mapAttrsToList
                (name: { url, hash }: pkgs.runCommand name {} ''
                  mkdir $out
                  cp -r ${builtins.fetchTarball {
                    inherit name url;
                    sha256 = zigDepHashes.${name} or (lib.warn "Missing hash for dependency: ${name}" "");
                  }} $out/${hash}
                '')
                info.dependencies;
            };
          } // args.passthru or {};
        }
      );
    };
  };
}
