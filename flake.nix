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
    zig2nix = {
      url = github:Cloudef/zig2nix;
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.parts.lib.mkFlake {inherit inputs;} (parts: {
      systems = ["x86_64-linux"];

      imports = [
        nix/devShells.nix
        nix/formatter.nix
        nix/overlays/zig
      ];

      perSystem = {
        inputs',
        config,
        ...
      }: {
        _module.args.pkgs =
          inputs'.nixpkgs.legacyPackages.appendOverlays
          [
            parts.config.flake.overlays.zig
          ];
      };
    });
}
