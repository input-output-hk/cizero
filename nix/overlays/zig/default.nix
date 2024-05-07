{
  inputs,
  lib,
  withSystem,
  ...
}: {
  flake.overlays.zig = final: prev:
    withSystem prev.stdenv.hostPlatform.system ({system, ...}: {
      buildZigPackage = prev.callPackage (
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
          zigRelease ? true,
          # Passed to `-Dtarget` if not null.
          zigTarget ? (
            let
              inherit (inputs.zig2nix.zig2nix-lib.${system}) zigTripleFromSystem resolveTargetSystem;
            in
              zigTripleFromSystem (resolveTargetSystem {platform = stdenv.targetPlatform;})
          ),
          # Passed to `-Ddynamic-linker` if not null.
          zigDynamicLinker ?
            if zigTarget == null
            then null
            else stdenv.cc.bintools.dynamicLinker,
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
                      zig_default_flags =
                        [
                          "--system"
                          finalAttrs.passthru.deps

                          (
                            if builtins.isBool zigRelease
                            then "-Drelease=${builtins.toJSON zigRelease}"
                            else "-Doptimize=${zigRelease}"
                          )

                          "-freference-trace"
                        ]
                        ++ lib.optional (zigTarget != null) "-Dtarget=${zigTarget}"
                        ++ lib.optional (zigDynamicLinker != null) "-Ddynamic-linker=${zigDynamicLinker}";
                    })
                  ];

                passthru =
                  {
                    packageInfo = final.zigPackageInfo (
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
      ) {};

      zigPackageInfo = buildZigZon:
        prev.runCommand "zig-package-info" {
          nativeBuildInputs = [prev.zig];
          buildZigZon = lib.fileContents buildZigZon;
          passthru = {inherit buildZigZon;};
        } ''
          cp ${./package-info.zig} main.zig

          substituteAllInPlace main.zig

          zig run > $out \
            --global-cache-dir "$TMPDIR" \
            -fstrip \
            main.zig
        '';
    });
}
