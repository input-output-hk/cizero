flakeRef: let
  job = let
    # mostly a port of `queryMetaStrings()` from the original `hydra-eval-jobs`
    # https://github.com/NixOS/hydra/blob/8f56209bd6f3b9ec53d50a23812a800dee7a1969/src/hydra-eval-jobs/hydra-eval-jobs.cc#L92
    stringProp = attr: subAttr:
      if builtins.isString attr
      then attr
      else if builtins.isList attr
      then builtins.concatStringsSep ", " (map (elem: stringProp elem subAttr) attr)
      else if builtins.isAttrs attr
      then toString attr.${subAttr}
      else "";
  in
    drv:
      {
        nixName = drv.name;
        inherit (drv) system drvPath;
        description = drv.meta.description or "";
        license = stringProp drv.meta.license or "" "shortName";
        homepage = drv.meta.homepage or "";
        maintainers = stringProp drv.meta.maintainers or [] "email";
        schedulingPriority = drv.meta.schedulingPriority or 100;
        timeout = drv.meta.timeout or 36000;
        maxSilent = drv.meta.maxSilent or 7200;
        isChannel = drv.meta.isHydraChannel or false;
        outputs = builtins.listToAttrs (
          map (output: {
            name = output;
            value = drv.${output}.outPath;
          })
          drv.outputs or [drv.outputName]
        );
      }
      // (
        if drv._hydraAggregate or false
        then {
          constituents = map (constituent: constituent.drvPath) (
            let
              inherit (builtins.partition builtins.isAttrs drv.constituents) right wrong;
            in
              right ++ map (constituent: result.${constituent}) wrong
          );
        }
        else {}
      );

  result = let
    collectAttrPaths = predicate: attrs: let
      internal = path: attrs: let
        inherit
          (
            builtins.partition
            (attrName: predicate attrs.${attrName})
            (builtins.attrNames attrs)
          )
          right
          wrong
          ;

        flattenDepth = depth: x:
          if builtins.isList x && depth >= 0
          then builtins.concatMap (flattenDepth (depth - 1)) x
          else [x];
      in
        map (attrName: path ++ [attrName]) right
        ++ (
          if attrs.recurseIntoAttrs or true
          then
            flattenDepth 1 (
              map
              (
                attrName:
                  internal
                  (path ++ [attrName])
                  attrs.${attrName}
              )
              (
                builtins.filter
                (attrName: builtins.isAttrs attrs.${attrName})
                wrong
              )
            )
          else []
        );
    in
      internal [] attrs;

    jobAttrs = let
      flake = builtins.getFlake flakeRef;
    in
      flake.outputs.hydraJobs
      or (flake.outputs.checks or throw "flake '${flake}' does not provide any Hydra jobs or checks");

    # copied from nixpkgs
    isDerivation = v: v.type or null == "derivation";

    jobAttrPaths = collectAttrPaths isDerivation jobAttrs;

    # TODO copy `showAttrPath` from nixpkgs
    showAttrPath = builtins.concatStringsSep ".";

    # copied from nixpkgs and simplified
    attrByPath = path: attrs: let
      attr = builtins.head path;
    in
      if path == []
      then attrs
      else attrByPath (builtins.tail path) attrs.${attr};
  in
    builtins.listToAttrs (
      map (path: {
        name = showAttrPath path;
        value = job (attrByPath path jobAttrs);
      })
      jobAttrPaths
    );
in
  result
