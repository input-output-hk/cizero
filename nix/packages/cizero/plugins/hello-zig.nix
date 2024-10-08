{inputs, ...}: {
  perSystem = {pkgs, ...}: {
    packages.cizero-plugin-hello-zig = pkgs.buildZigPackage {
      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/hello-zig
        ../../../../pdk/zig
        ../../../../src
        ../../../../lib
      ];

      buildZigZon = "plugins/hello-zig/build.zig.zon";

      zigDepsHash = "sha256-RZ2e02HBVvIYdqwG1JMrAnhhndYmr04I88hYAZpB38E=";

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
