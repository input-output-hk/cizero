{inputs, ...}: {
  imports = with inputs; [
    mission-control.flakeModule
    flake-root.flakeModule
    make-shell.flakeModules.default
  ];

  perSystem = {
    inputs',
    config,
    lib,
    pkgs,
    ...
  }: {
    make-shell.imports = [
      ({name, ...}: {
        name = "devShell-${name}";

        inputsFrom = [
          config.mission-control.devShell
          config.flake-root.devShell
        ];
      })
    ];

    make-shells.default = {
      packages = with pkgs; [zls];

      shellHook = ''
        # TODO remove once merged: https://github.com/NixOS/nixpkgs/pull/310588
        # Set to `/build/tmp.XXXXXXXXXX` by the zig hook.
        unset ZIG_GLOBAL_CACHE_DIR

        export ZIG_LOCAL_CACHE_DIR="$FLAKE_ROOT/.zig-cache"
      '';
    };
  };
}
