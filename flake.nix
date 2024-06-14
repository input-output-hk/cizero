{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
    nix.url = github:NixOS/nix/2.19-maintenance;
    parts.url = github:hercules-ci/flake-parts;
    mission-control.url = github:Platonic-Systems/mission-control;
    flake-root.url = github:srid/flake-root;
    treefmt-nix = {
      url = github:numtide/treefmt-nix;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    inclusive = {
      url = github:input-output-hk/nix-inclusive;
      inputs.stdlib.follows = "parts/nixpkgs-lib";
    };
    zig2nix = {
      url = github:Cloudef/zig2nix;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ghc-wasm-meta.url = "https://gitlab.haskell.org/ghc/ghc-wasm-meta/-/archive/master/ghc-wasm-meta-master.tar.gz";
  };

  outputs = inputs:
    inputs.parts.lib.mkFlake {inherit inputs;} (parts: {
      systems = ["x86_64-linux"];

      imports = [
        nix/checks
        nix/packages
        nix/overlays
        nix/devShells.nix
        nix/formatter.nix
        nix/hydraJobs.nix
        nix/nixosModules.nix
      ];

      perSystem = {
        inputs',
        config,
        ...
      }: {
        _module.args.pkgs =
          inputs'.nixpkgs.legacyPackages.extend
          parts.config.flake.overlays.zig;
      };
    });
}
