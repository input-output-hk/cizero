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
            rev = "31a7f22b800c091962726de2dd29f10a8eb25b78";
            hash = "sha256-zVD+1MYrp5kgib7O0xygMPv6cOAdBK7ggTYojbZoOao=";
          };

          postPatch = ''
            substituteInPlace lib/std/zig/system.zig \
              --replace '"/usr/bin/env"' '"${pkgs.coreutils}/bin/env"'
          '';
        }))
        .override {
          llvmPackages = pkgs.llvmPackages_17;
        };

      zls = config.overlayAttrs.buildZigPackage rec {
        src = pkgs.fetchFromGitHub {
          owner = "zigtools";
          repo = "zls";
          rev = "96eddd067615efd9a88fa596dfa4c75943302885";
          hash = "sha256-mXdiiWofQEzOP4o8ZrS9NtZ3gzwxLkr/4dLOGYBrlTQ=";
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

        zigDepsHash = "sha256-qhC7BvIVJMOEBdbJ9NaK+Xngjs+PfopwZimuPc58xhU=";

        zigBuildFlags = [
          "-Dversion_data_path=${passthru.langref}"
        ];
        zigCheckFlags = zigBuildFlags;

        zigRelease = "ReleaseSafe";

        passthru.langref = config.packages.zig.src + /doc/langref.html.in;

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

                        "-freference-trace"
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

                        # create an empty directory if there are no dependencies
                        mv "$TMPDIR"/cache/p $out || mkdir $out
                      '';
                  }
                  // args.passthru or {};
              }
          )
      ) {inherit (config.packages) zig;};
    };
  };
}
