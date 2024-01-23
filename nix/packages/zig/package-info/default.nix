{
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    overlayAttrs.zigPackageInfo = buildZigZon:
      pkgs.runCommand "zig-package-info" {
        nativeBuildInputs = [config.overlayAttrs.zig];
        buildZigZon = lib.fileContents buildZigZon;
        passthru = {inherit buildZigZon;};
      } ''
        cp ${./main.zig} main.zig

        substituteAllInPlace main.zig

        zig run > $out \
          --global-cache-dir "$TMPDIR" \
          -fstrip \
          main.zig
      '';
  };
}
