{
  perSystem = { config, pkgs, ... }: {
    devShells = {
      default = pkgs.mkShell {
        packages = [ config.packages.zls ];
        inputsFrom = [ config.packages.cizero ];
      };

      crystal = pkgs.mkShell {
        packages = with pkgs; [ crystal crystalline llvmPackages_16.bintools wasm-tools just ];
        shellHook = let
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
        in ''
          root="$(git rev-parse --show-toplevel)"
          ln -sfT ${wasi-libs} "$root"/plugins/hello/wasi-libs
        '';
      };
    };
  };
}
