{
  perSystem = {
    inputs',
    config,
    pkgs,
    ...
  }: {
    packages = {
      zig =
        (inputs'.nixpkgs.legacyPackages.zig.overrideAttrs (oldAttrs: rec {
          version = src.rev;

          src = oldAttrs.src.override {
            rev = "0.12.0";
            hash = "sha256-RNZiUZtaKXoab5kFrDij6YCAospeVvlLWheTc3FGMks=";
          };

          postPatch = ''
            substituteInPlace lib/std/zig/system.zig \
              --replace '"/usr/bin/env"' '"${pkgs.coreutils}/bin/env"'
          '';
        }))
        .override {
          llvmPackages = pkgs.llvmPackages_17;
        };

      zls = pkgs.buildZigPackage rec {
        src = pkgs.fetchFromGitHub {
          owner = "zigtools";
          repo = "zls";
          rev = config.packages.zig.version;
          hash = "sha256-2iVDPUj9ExgTooDQmCCtZs3wxBe2be9xjzAk9HedPNY=";
          fetchSubmodules = true;
        };

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
  };
}
