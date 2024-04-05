{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-23.11;
    nix = {
      url = github:NixOS/nix/2.19-maintenance;
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
  };

  outputs = inputs:
    inputs.parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];

      imports = [
        nix/checks
        nix/packages
        nix/devShells.nix
        nix/overlays.nix
        nix/formatter.nix
        nix/hydraJobs.nix
        nix/nixosModules.nix
      ];
    };
}
