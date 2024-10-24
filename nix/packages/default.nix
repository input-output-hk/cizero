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
      name = "cizero-full";
      paths = with config.packages; [
        cizero
        cizero-plugin-hello-zig
        cizero-plugin-hello-crystal
        cizero-plugin-hydra-eval-jobs
      ];
    };
  };
}
