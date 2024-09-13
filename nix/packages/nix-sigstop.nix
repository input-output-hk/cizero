{inputs, ...}: {
  perSystem = {pkgs, ...}: {
    packages.nix-sigstop = pkgs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../.. [
        ../../nix-sigstop
        ../../lib
      ];

      zigDepsHash = "sha256-30+6mA5JwgQnajrl0/LcFhPrTom+J/6cL0EaybM9p0k=";

      buildZigZon = "nix-sigstop/build.zig.zon";

      meta.mainProgram = "nix-sigstop";
    };
  };
}
