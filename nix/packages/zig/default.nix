{inputs, ...}: {
  imports = [
    inputs.parts.flakeModules.easyOverlay
    ./package-info
  ];

  perSystem = {
    config,
    pkgs,
    ...
  }: {
    packages = {
      zig =
        (pkgs.zig.overrideAttrs (oldAttrs: rec {
          version = src.rev;

          src = oldAttrs.src.override {
            rev = "993a83081a975464d1201597cf6f4cb7f6735284";
            hash = "sha256-dNje2++gW+Uyz8twx9pAq7DQT/DGn4WupBTdc9cTBNw=";
          };

          postPatch = ''
            substituteInPlace lib/std/zig/system.zig \
              --replace '"/usr/bin/env"' '"${pkgs.coreutils}/bin/env"'
          '';

          # do not build docs as the doc tests fail for windows
          outputs = ["out"];
          postBuild = "";
          postInstall = "";
        }))
        .override {
          llvmPackages = pkgs.llvmPackages_17;
        };

      zls = config.overlayAttrs.buildZigPackage rec {
        src = pkgs.fetchFromGitHub {
          owner = "zigtools";
          repo = "zls";
          rev = "a8a83b6ad21e382c49474e8a9ffe35a3e510de3c";
          hash = "sha256-QR0hKolbEcEeTOsbf4CBOmj9nG7YG0fnv72kM8wkU28=";
          fetchSubmodules = true;
        };

        zigDepsHash = "sha256-1KBYMJ82o3IQKPcQx0sBfsoKxGOdTe5bCiGQkO6HHMA=";

        zigBuildFlags = [
          "-Dversion_data_path=${passthru.langref}"
        ];
        zigCheckFlags = zigBuildFlags;

        zigRelease = "ReleaseSafe";

        passthru.langref = builtins.fetchurl {
          url = "https://raw.githubusercontent.com/ziglang/zig/${config.packages.zig.src.rev}/doc/langref.html.in";
          sha256 = "1m1qhfn2jkl0yp9hidxw3jgb8yjns631nnc8kxx2np4kvdcqmxgy";
        };

        inherit (pkgs.zls) meta;
      };
    };

    overlayAttrs = {
      inherit (config.packages) zig;

      buildZigPackage = pkgs.callPackage (
        {
          lib,
          stdenv,
          runCommand,
          zig,
        }: args @ {
          src,
          buildZigZon ? "build.zig.zon",
          zigDepsHash,
          # Can be a boolean for for `-Drelease` or a string for `-Doptimize`.
          # `-Doptimize` was replaced with `-Drelease` in newer zig versions
          # when `build.zig` declares a preferred optimize mode.
          zigRelease ? true,
          ...
        }:
          stdenv.mkDerivation (
            finalAttrs: let
              info = lib.importJSON finalAttrs.passthru.packageInfo;
            in
              {
                pname = info.name;
                inherit (info) version;

                postPatch = lib.optionalString (finalAttrs.passthru ? deps) ''
                  ln --symbolic ${finalAttrs.passthru.deps} "$ZIG_GLOBAL_CACHE_DIR"/p
                  cd ${lib.escapeShellArg (builtins.dirOf buildZigZon)}
                '';

                doCheck = true;
              }
              // builtins.removeAttrs args [
                "buildZigZon"
                "zigDepsHash"
              ]
              // {
                nativeBuildInputs =
                  args.nativeBuildInputs
                  or []
                  ++ [
                    zig
                    (zig.hook.overrideAttrs {
                      zig_default_flags = [
                        # Not passing -Dcpu=baseline as that overrides our target options from build.zig.

                        (
                          if builtins.typeOf zigRelease == "bool"
                          then "-Drelease=${builtins.toJSON zigRelease}"
                          else "-Doptimize=${zigRelease}"
                        )
                      ];
                    })
                  ];

                passthru =
                  {
                    packageInfo = config.overlayAttrs.zigPackageInfo (
                      lib.optionalString (!lib.hasPrefix "/" buildZigZon) "${finalAttrs.src}/"
                      + buildZigZon
                    );

                    # builds the $ZIG_GLOBAL_CACHE_DIR/p directory
                    deps =
                      runCommand (with finalAttrs; "${pname}-${version}-deps") {
                        nativeBuildInputs = [zig];

                        outputHashMode = "recursive";
                        outputHashAlgo = "sha256";
                        outputHash = zigDepsHash;
                      } ''
                        mkdir "$TMPDIR"/cache

                        cd ${src}
                        cd ${lib.escapeShellArg (builtins.dirOf buildZigZon)}
                        zig build --fetch \
                          --cache-dir "$TMPDIR" \
                          --global-cache-dir "$TMPDIR"/cache

                        mv "$TMPDIR"/cache/p $out
                      '';
                  }
                  // args.passthru or {};
              }
          )
      ) {inherit (config.packages) zig;};
    };
  };
}
