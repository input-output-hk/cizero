{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
    parts.url = github:hercules-ci/flake-parts;
    mission-control.url = github:Platonic-Systems/mission-control;
    flake-root.url = github:srid/flake-root;
    inclusive = {
      url = github:input-output-hk/nix-inclusive;
      inputs.stdlib.follows = "parts/nixpkgs-lib";
    };
  };

  outputs = inputs: inputs.parts.lib.mkFlake { inherit inputs; } {
    systems = ["x86_64-linux"];

    imports = [
      nix/packages
      nix/devShells.nix
    ];
  };
}
