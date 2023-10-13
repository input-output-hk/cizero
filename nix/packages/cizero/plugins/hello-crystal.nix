{inputs, ...}: {
  perSystem = {pkgs, ...}: let
    pluginName = "hello-crystal";
  in {
    packages."cizero-plugin-${pluginName}" = pkgs.stdenv.mkDerivation rec {
      pname = "cizero-plugin-${pluginName}";
      version = "0.0.0";

      src = inputs.inclusive.lib.inclusive ../../../.. [
        ../../../../plugins/${pluginName}
        ../../../../pdk/crystal
      ];

      buildInputs = with pkgs; [crystal llvmPackages_16.bintools];

      shellHook = ''
        # override phase functions for integration with `nix develop`
        for phaseName in configure build; do
            phase=''${phaseName}Phase
            eval "function $phase {
                ''${!phase}
            }"
        done

        configurePhase
        trap rm\ "$PWD"/wasi-libs EXIT

        tput bold
        echo -n 'Build by running: '
        tput setaf 4 # blue
        echo buildPhase
        tput sgr0 # reset
      '';

      configurePhase = let
        wasi-libs = pkgs.fetchurl {
          name = "wasm32-wasi-libs-0.0.3";
          recursiveHash = true;
          downloadToTemp = true;
          url = https://github.com/lbguilherme/wasm-libs/releases/download/0.0.3/wasm32-wasi-libs.tar.gz;
          hash = "sha256-GCaU5teS8fLjpq0pE98+Tyia7HiiigwFFAVqo3PpRXo=";
          postFetch = ''
            mkdir -p $out
            tar xvf $downloadedFile -C $out
          '';
        };
      in ''
        runHook preConfigure

        cd plugins/${pluginName}
        ln -sfT ${wasi-libs} wasi-libs

        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild

        crystal build ${pluginName}.cr -o ${pluginName}.o.wasm --error-trace --verbose --cross-compile --target wasm32-wasi
        wasm-ld ${pluginName}.o.wasm -o ${pluginName}.wasm -Lwasi-libs -lc -lpcre2-8

        runHook postBuild
      '';

      installPhase = ''
        mkdir -p $out/libexec/cizero/plugins
        mv ${pluginName}.wasm $out/libexec/cizero/plugins/${pluginName}.wasm
      '';
    };
  };
}
