{
  perSystem = {pkgs, ...}: {
    packages.nix-sigstop = pkgs.buildZigPackage {
      src = ../../nix-sigstop;

      zigDepsHash = "sha256-JB2gaSv+GI4SzXWSuGjYkgKr8Tx3DdYZJvT3eyu8Bnc=";

      meta.mainProgram = "nix-sigstop";
    };
  };
}
