{
  imports = [
    ./cizero
    ./zig
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
        cizero-plugin-foo
        cizero-plugin-hello
      ];
    };
  };
}
