{
  perSystem = {
    inputs',
    config,
    pkgs,
    ...
  }: {
    packages = {
      zig =
        (inputs'.nixpkgs.legacyPackages.zig.overrideAttrs (oldAttrs: rec {
          version = src.rev;

          src = oldAttrs.src.override {
            rev = "31a7f22b800c091962726de2dd29f10a8eb25b78";
            hash = "sha256-zVD+1MYrp5kgib7O0xygMPv6cOAdBK7ggTYojbZoOao=";
          };

          postPatch = ''
            substituteInPlace lib/std/zig/system.zig \
              --replace '"/usr/bin/env"' '"${pkgs.coreutils}/bin/env"'
          '';
        }))
        .override {
          llvmPackages = pkgs.llvmPackages_17;
        };

      zls = pkgs.buildZigPackage rec {
        src = pkgs.fetchFromGitHub {
          owner = "zigtools";
          repo = "zls";
          rev = "96eddd067615efd9a88fa596dfa4c75943302885";
          hash = "sha256-mXdiiWofQEzOP4o8ZrS9NtZ3gzwxLkr/4dLOGYBrlTQ=";
          fetchSubmodules = true;
        };

        patches = [
          # The issue linked in the diff has been fixed so we can remove the check until upstream catches up.
          # We need to do this to allow compilation with nightly zig.
          (builtins.toFile "19071.diff" ''
            diff --git a/src/config_gen/config_gen.zig b/src/config_gen/config_gen.zig
            index 95ad1d7..6e41cca 100644
            --- a/src/config_gen/config_gen.zig
            +++ b/src/config_gen/config_gen.zig
            @@ -943,3 +942,0 @@ fn httpGET(allocator: std.mem.Allocator, uri: std.Uri) !Response {
            -    // TODO remove duplicate logic once https://github.com/ziglang/zig/issues/19071 has been fixed
            -    comptime std.debug.assert(zig_builtin.zig_version.order(.{ .major = 0, .minor = 12, .patch = 0 }) == .lt);
            -
          '')
        ];

        zigDepsHash = "sha256-qhC7BvIVJMOEBdbJ9NaK+Xngjs+PfopwZimuPc58xhU=";

        zigBuildFlags = [
          "-Dversion_data_path=${passthru.langref}"
        ];
        zigCheckFlags = zigBuildFlags;

        zigRelease = "ReleaseSafe";

        passthru.langref = config.packages.zig.src + /doc/langref.html.in;

        inherit (pkgs.zls) meta;
      };
    };
  };
}
