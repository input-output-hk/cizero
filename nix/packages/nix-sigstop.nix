{inputs, ...}: {
  perSystem = {pkgs, ...}: {
    packages.nix-sigstop = pkgs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../.. [
        ../../nix-sigstop
        ../../lib
      ];

      zigDepsHash = "sha256-qlJqP2rac/xxQzOekUi9aYYCAdQj81ce7L90f1Rvzzk=";

      buildZigZon = "nix-sigstop/build.zig.zon";
    };
  };
}
