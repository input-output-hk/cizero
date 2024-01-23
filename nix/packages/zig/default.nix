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

        zigDepHashes = {
          diffz = "0p40avmwv0zpw6abx13cxcz5hf3mxbacay352clgf693grb4ylf9";
          known_folders = "1idmgvjnais9k4lgwwg0sm72lwajngzc6xw82v06bbsksj69ihp2";
        };

        zigBuildFlags = [
          "-Dversion_data_path=${passthru.langref}"
        ];
        zigCheckFlags = zigBuildFlags;

        dontConfigure = true;
        dontBuild = true;
        dontInstall = false;

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
          symlinkJoin,
          runCommand,
          zig,
        }: args @ {
          buildZigZon ? "build.zig.zon",
          zigDepHashes ? {},
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
                  ln -s ${finalAttrs.passthru.deps} "$ZIG_GLOBAL_CACHE_DIR"/p
                '';

                doCheck = true;
                dontInstall = true;
              }
              // builtins.removeAttrs args [
                "buildZigZon"
                "zigDepHashes"
              ]
              // {
                nativeBuildInputs =
                  args.nativeBuildInputs
                  or []
                  ++ [
                    zig
                    zig.hook
                  ];

                passthru =
                  {
                    packageInfo = config.overlayAttrs.zigPackageInfo (
                      lib.optionalString (!lib.hasPrefix "/" buildZigZon) "${finalAttrs.src}/"
                      + buildZigZon
                    );

                    # builds the $ZIG_GLOBAL_CACHE_DIR/p directory
                    deps = symlinkJoin {
                      name = with finalAttrs; "${pname}-${version}-deps";
                      paths =
                        if builtins.isAttrs (info.dependencies or null)
                        then
                          lib.mapAttrsToList
                          (
                            name: {
                              url ? null,
                              hash ? null,
                              path ? null,
                            }:
                              assert url != null -> hash != null;
                              assert url != null -> path == null;
                              assert path != null -> url == null;
                                runCommand name {
                                  nativeBuildInputs = lib.optional (path != null) zig;
                                } (
                                  if url != null
                                  then ''
                                    mkdir $out
                                    cp --archive -recursive ${builtins.fetchTarball {
                                      inherit name url;
                                      sha256 = zigDepHashes.${name} or (lib.warn "Missing hash for dependency: ${name}" "");
                                    }} $out/${hash}
                                  ''
                                  else ''
                                    zig fetch --global-cache-dir $out \
                                      ${lib.escapeShellArg "${builtins.dirOf finalAttrs.passthru.packageInfo.passthru.buildZigZon}/${path}"}
                                  ''
                                )
                          )
                          info.dependencies
                        else [];
                    };
                  }
                  // args.passthru or {};
              }
          )
      ) {inherit (config.packages) zig;};
    };
  };
}
