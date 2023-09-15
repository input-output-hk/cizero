{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
    parts.url = github:hercules-ci/flake-parts;
    inclusive = {
      url = github:input-output-hk/nix-inclusive;
      inputs.stdlib.follows = "parts/nixpkgs-lib";
    };
    extism = {
      url = github:extism/extism/v0.5.0;
      flake = false;
    };
  };

  outputs = inputs: inputs.parts.lib.mkFlake { inherit inputs; } {
    systems = ["x86_64-linux"];

    imports = [
      nix/packages.nix
      nix/devShells.nix
    ];
  };
}
