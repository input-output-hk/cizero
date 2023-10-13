{
  perSystem = { config, pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = [ config.packages.zls pkgs.just ];
      inputsFrom = [ config.packages.cizero ];
    };

    devShells.crystal = let
      wasi-libs = pkgs.fetchurl {
        name = "wasm32-wasi-libs-0.0.3";
        recursiveHash = true;
        downloadToTemp = true;
        url =  "https://github.com/lbguilherme/wasm-libs/releases/download/0.0.3/wasm32-wasi-libs.tar.gz";
        hash = "sha256-GCaU5teS8fLjpq0pE98+Tyia7HiiigwFFAVqo3PpRXo=";
        postFetch = ''
          mkdir -p $out
          tar xvf $downloadedFile -C $out
        '';
      };
     in pkgs.mkShell {
      packages = [ pkgs.crystal pkgs.crystalline pkgs.llvmPackages_16.bintools pkgs.wasm-tools pkgs.just ];
      shellHook = ''
        ln -sfT ${wasi-libs} wasi-libs
      '';
    };
  };
}
