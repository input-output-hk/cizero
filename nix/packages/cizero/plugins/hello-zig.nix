{inputs, ...}: {
  perSystem = {pkgs, ...}: {
    packages.cizero-plugin-hello-zig = pkgs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/hello-zig
        ../../../../pdk/zig
        ../../../../src
      ];

      buildZigZon = "plugins/hello-zig/build.zig.zon";

      zigDepsHash = "sha256-58zfTjxx0OUN6w12QaJRgabP4bec7mH4lKaG3AJR0PU=";

      zigTarget = null;

      nativeCheckInputs = with pkgs; [
        wasmtime
      ];

      preCheck = ''
        # for wasmtime cache
        export HOME="$TMPDIR"
      '';
    };
  };
}
