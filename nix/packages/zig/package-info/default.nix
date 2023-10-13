{
  perSystem = {
    lib,
    pkgs,
    ...
  }: {
    overlayAttrs.zigPackageInfo = buildZigZon:
      pkgs.runCommand "zig-package-info" {
        nativeBuildInputs = with pkgs; [zig];
        buildZigZon = lib.fileContents buildZigZon;
      } ''
        cp ${./main.zig} main.zig

        substituteAllInPlace main.zig

        zig run > $out \
          --global-cache-dir "$TMPDIR" \
          -O ReleaseFast \
          main.zig
      '';
  };
}
