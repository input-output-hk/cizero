{
  imports = [
    ./cizero
  ];

  perSystem = {
    config,
    pkgs,
    ...
  }: {
    packages.default = pkgs.symlinkJoin {
      name = "cizero-with-plugins";
      paths = with config.packages; [
        cizero
        cizero-plugin-hello-zig
        cizero-plugin-hello-crystal
        cizero-plugin-hello-haskell
        cizero-plugin-hydra-eval-jobs
      ];
    };
  };
}
