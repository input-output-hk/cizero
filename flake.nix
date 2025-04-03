{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
    nix.url = github:NixOS/nix/2.19-maintenance;
    parts.url = github:hercules-ci/flake-parts;
    mission-control.url = github:Platonic-Systems/mission-control;
    flake-root.url = github:srid/flake-root;
    make-shell.url = github:nicknovitski/make-shell;
    treefmt-nix = {
      url = github:numtide/treefmt-nix;
      inputs.nixpkgs.follows = "nixpkgs";
    };
    inclusive = {
      url = github:input-output-hk/nix-inclusive;
      inputs.stdlib.follows = "parts/nixpkgs-lib";
    };
    utils = {
      url = github:dermetfan/utils.zig;
      inputs = {
        nixpkgs.follows = "nixpkgs";
        parts.follows = "parts";
        make-shell.follows = "make-shell";
        treefmt-nix.follows = "treefmt-nix";
        inclusive.follows = "inclusive";
      };
    };
    nix-sigstop = {
      url = github:input-output-hk/nix-sigstop;
      inputs = {
        nixpkgs.follows = "nixpkgs";
        parts.follows = "parts";
        treefmt-nix.follows = "treefmt-nix";
        inclusive.follows = "inclusive";
        utils.follows = "utils";
      };
    };
  };

  outputs = inputs:
    inputs.parts.lib.mkFlake {inherit inputs;} (_: {
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

      perSystem = {inputs', ...}: {
        _module.args.pkgs = inputs'.nixpkgs.legacyPackages.extend inputs.utils.overlays.zig;
      };
    });
}
