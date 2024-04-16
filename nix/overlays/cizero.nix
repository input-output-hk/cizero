{
  lib,
  withSystem,
  ...
}: {
  flake.overlays.cizero-plugin-hydra-eval-jobs = _final: prev:
    withSystem prev.stdenv.hostPlatform.system ({config, ...}: {
      # Unfortunately we cannot use `symlinkJoin` or similar for this
      # because each executable in `/bin` is a wrapper that prefixes `$PATH` referring to `$out`.
      # That is impossible to overwrite from another build so we need to make our change in the original build.
      hydra_unstable = prev.hydra_unstable.overrideAttrs (oldAttrs: {
        postInstall = ''
          ${oldAttrs.postInstall}
          ln --symbolic --force ${lib.getExe config.packages.cizero-plugin-hydra-eval-jobs.hydra-eval-jobs} $out/bin/hydra-eval-jobs
        '';
      });
    });
}
