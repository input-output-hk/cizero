{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixpkgs-unstable;
    "nixpkgs-24.05".url = github:NixOS/nixpkgs/release-24.05;
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
          inputs'.nixpkgs.legacyPackages.appendOverlays
          [
            parts.config.flake.overlays.zig
            (_final: prev: {
              # Must use older wasmtime until the fix for https://github.com/bytecodealliance/wasmtime/issues/8890 lands in nixpkgs.
              inherit (inputs."nixpkgs-24.05".legacyPackages.${prev.system}) wasmtime;
            })
          ];
      };
    });
}
