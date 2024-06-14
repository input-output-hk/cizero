{inputs, ...}: {
  perSystem = {pkgs,inputs', ...}: let
    pluginName = "hello-haskell";
  in {
    packages."cizero-plugin-${pluginName}" = pkgs.stdenv.mkDerivation rec {
      pname = "cizero-plugin-${pluginName}";
      version = "0.0.0";

      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/${pluginName}
        # ../../../../pdk/crystal
      ];

      buildInputs = [inputs'.ghc-wasm-meta.packages.wasm32-wasi-ghc-gmp];

      buildPhase = ''
        wasm32-wasi-ghc plugins/${pluginName}/${pluginName}.hs \
          -optl-Wl,--export=pdk_test_nix_on_eval

        # wasm32-wasi-ghc \
        #   plugins/${pluginName}/${pluginName}.hs \
        #   -no-hs-main \
        #   -optl-mexec-model=reactor \
        #   -optl-Wl,--export=hs_init,--export=pdk_test_nix_on_eval
      '';

      installPhase = ''
        mkdir -p $out/libexec/cizero/plugins
        mv plugins/${pluginName}/${pluginName}.wasm $out/libexec/cizero/plugins/${pluginName}.wasm
      '';
    };
  };
}
