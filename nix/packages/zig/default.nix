{inputs, ...}: {
  imports = [
    inputs.parts.flakeModules.easyOverlay
    ./package-info
  ];

  perSystem = {
    system,
    config,
    pkgs,
    lib,
    ...
  }: {
    packages = {
      zig =
        # Zig built from source reliably OOMs even when building the result of `zig init`.
        # https://github.com/Cloudef/zig2nix and https://github.com/erikarvstedt/nix-zig-build
        # are also affected so we resort to prebuilt binaries for now.
        /*
        (pkgs.zig.overrideAttrs (oldAttrs: rec {
          version = src.rev;

          src = oldAttrs.src.override {
            rev = "26e895e3dc4ff1b7ac235414a356840bccb4fb1e";
            hash = "sha256-LmE03OUjKZnkqRIWISyN1XXns1JyyHooGhthTeFjfv8=";
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
        */
        let
          zig = inputs.zig-overlay.packages.${system}.master-2024-03-17.overrideAttrs (oldAttrs: {
            installPhase = ''
              ${oldAttrs.installPhase}
              mv $out/bin/{zig,.zig-unwrapped}
              cat > $out/bin/zig <<EOF
              #! ${lib.getExe pkgs.dash}
              exec ${lib.getExe pkgs.proot} \\
                --bind=${pkgs.coreutils}/bin/env:/usr/bin/env \\
                $out/bin/.zig-unwrapped "\$@"
              EOF
              chmod +x $out/bin/zig
            '';
          });
          # zig-overlay does not expose a setup hook, see https://github.com/mitchellh/zig-overlay/issues/33
          # TODO remove once https://github.com/mitchellh/zig-overlay/pull/37 is merged
          passthru.hook = pkgs.zig.hook.override {
            zig =
              zig
              // {
                # Not accurate as this is meta from the version from nixpkgs but we need this to evaluate.
                inherit (pkgs.zig) meta;
              };
          };
        in
          zig // passthru // {inherit passthru;};

      zls = config.overlayAttrs.buildZigPackage rec {
        src = pkgs.fetchFromGitHub {
          owner = "zigtools";
          repo = "zls";
          rev = "fd3b5afe51ee57dbfba2db317e48a13abf741039";
          hash = "sha256-n3fC1pem18qvRZsesjVLFxDvAzcK3W/FiWiao+pC2vQ=";
          fetchSubmodules = true;
        };

        patches = [
          # The issue linked in the diff has been fixed so we can remove the check until upstream catches up.
          # We need to do this to allow compilation with nightly zig.
          (builtins.toFile "19071.diff" ''
            diff --git a/src/config_gen/config_gen.zig b/src/config_gen/config_gen.zig
            index 95ad1d7..6e41cca 100644
            --- a/src/config_gen/config_gen.zig
            +++ b/src/config_gen/config_gen.zig
            @@ -943,3 +942,0 @@ fn httpGET(allocator: std.mem.Allocator, uri: std.Uri) !Response {
            -    // TODO remove duplicate logic once https://github.com/ziglang/zig/issues/19071 has been fixed
            -    comptime std.debug.assert(zig_builtin.zig_version.order(.{ .major = 0, .minor = 12, .patch = 0 }) == .lt);
            -
          '')
        ];

        zigDepsHash = "sha256-HYrdL9k7ITDemanT7vHVjEPWtjDDskvY6It83tdHbSk=";

        zigBuildFlags = [
          "-Dversion_data_path=${passthru.langref}"
        ];
        zigCheckFlags = zigBuildFlags;

        zigRelease = "ReleaseSafe";

        # We can do this the simple way again once zig build from source works, see above.
        # passthru.langref = config.packages.zig.src + /doc/langref.html.in;
        passthru.langref = pkgs.fetchurl {
          url = let
            commit = "f88a971e4ff211b78695609b4482fb886f30a1af";
            commitPrefixFromPackage = builtins.head (builtins.match ''.*\+(.*)'' config.packages.zig.version);
          in
            assert lib.assertMsg (lib.hasPrefix commitPrefixFromPackage commit) ''
              ZLS langref version does not match zig compiler version.
              ZLS langref version:  ${commit}
              Zig compiler version: ${commitPrefixFromPackage}
            ''; "https://raw.githubusercontent.com/ziglang/zig/${commit}/doc/langref.html.in";
          hash = "sha256-uFb2lRKsi5q9nemtPraBNWPTADMLB0YhH+O52lSoQDU=";
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
                    (zig.hook.overrideAttrs {
                      zig_default_flags = [
                        # Not passing -Dcpu=baseline as that overrides our target options from build.zig.

                        "--system"
                        finalAttrs.passthru.deps

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
                    # newer zig versions can consume this directly using --system
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
