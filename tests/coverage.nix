# The (host, endpoint) coverage table. Every pair carries exactly ONE declared status, so
# "it only evaluates" is a visible name, never a default the suite quietly hands out:
#
#   booted     an e2e boots the artifact (or, for phase 2, runs it against one) and reads
#              the witness off the running system
#   hole       refused at eval by a law — asserted red, not skipped
#   eval-only  forced to a .drv and NOTHING more; a named debt, not a proof
#
# Both halves are ENFORCED: holes must match the laws, and every `booted` must be claimed
# by an e2e's own witness declaration — the same trick in both directions, so the table
# cannot quietly drift from what the suite actually proves.
{ pkgs, witnessed }:

let
  inherit (pkgs) lib;

  endpointSet = [
    "image-iso" "image-raw" "image-qcow2" "image-kexec" "image-ipxe"
    "image-iso-install" "image-raw-install" "image-qcow2-install"
    "image-kexec-install" "image-ipxe-install"
    "image-raw-install-inmemory" "image-qcow2-install-inmemory"
    "image-secrets-vfat" "image-secrets-iso" "image-secrets-json"
    "image-personalize" "image-personalize-iso" "image-personalize-kexec"
    "closure" "closure-live"
  ];

  statuses = [ "booted" "hole" "eval-only" ];

  # The holes the LAWS derive: a zfs host's runtime disk endpoints are L2, and a squashfs
  # host's install endpoints are L6 — its store is written by the image, never by an install.
  installEndpoints = [
    "image-iso-install" "image-raw-install" "image-qcow2-install"
    "image-kexec-install" "image-ipxe-install"
    "image-raw-install-inmemory" "image-qcow2-install-inmemory"
  ];
  lawHoles = {
    ext4 = [ ];
    memory = installEndpoints;
    plain = [ ];
    arm = [ ];
    "ext4-install" = [ ];
    "image-install" = [ ];
    zfs = [ "image-raw" "image-qcow2" ];
    "zfs-enc" = [ "image-raw" "image-qcow2" ];
  };

  table = {
    ext4 = {
      image-raw = "booted";
      image-iso = "booted";
      image-qcow2 = "eval-only";
      image-kexec = "booted";
      image-ipxe = "eval-only";
      image-raw-install = "eval-only";
      image-qcow2-install = "eval-only";
      image-iso-install = "eval-only";
      image-kexec-install = "eval-only";
      image-ipxe-install = "eval-only";
      image-raw-install-inmemory = "eval-only";
      image-qcow2-install-inmemory = "eval-only";
      image-secrets-vfat = "booted";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "booted";
      image-personalize-iso = "booted";
      image-personalize-kexec = "booted";
      closure = "booted";
      closure-live = "booted";
    };
    memory = {
      image-raw = "booted";
      image-iso = "eval-only";
      image-qcow2 = "eval-only";
      image-kexec = "eval-only";
      image-ipxe = "eval-only";
      image-raw-install = "hole";
      image-qcow2-install = "hole";
      image-iso-install = "hole";
      image-kexec-install = "hole";
      image-ipxe-install = "hole";
      image-raw-install-inmemory = "hole";
      image-qcow2-install-inmemory = "hole";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "eval-only";
      image-personalize-iso = "eval-only";
      image-personalize-kexec = "eval-only";
      closure = "booted";
      closure-live = "eval-only";
    };
    zfs = {
      image-raw = "hole";
      image-qcow2 = "hole";
      image-iso = "eval-only";
      image-kexec = "eval-only";
      image-ipxe = "eval-only";
      image-raw-install = "booted";
      image-qcow2-install = "eval-only";
      image-iso-install = "booted";
      image-kexec-install = "booted";
      image-ipxe-install = "eval-only";
      image-raw-install-inmemory = "eval-only";
      image-qcow2-install-inmemory = "eval-only";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "booted";
      image-personalize-iso = "booted";
      image-personalize-kexec = "booted";
      closure = "booted";
      closure-live = "eval-only";
    };
    "zfs-enc" = {
      image-raw = "hole";
      image-qcow2 = "hole";
      image-iso = "eval-only";
      image-kexec = "eval-only";
      image-ipxe = "eval-only";
      image-raw-install = "eval-only";
      image-qcow2-install = "eval-only";
      image-iso-install = "eval-only";
      image-kexec-install = "booted";
      image-ipxe-install = "eval-only";
      image-raw-install-inmemory = "eval-only";
      image-qcow2-install-inmemory = "eval-only";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "eval-only";
      image-personalize-iso = "eval-only";
      image-personalize-kexec = "booted";
      closure = "eval-only";
      closure-live = "eval-only";
    };
    arm = {
      image-raw = "eval-only";
      image-iso = "eval-only";
      image-qcow2 = "eval-only";
      image-kexec = "eval-only";
      image-ipxe = "eval-only";
      image-raw-install = "eval-only";
      image-qcow2-install = "eval-only";
      image-iso-install = "eval-only";
      image-kexec-install = "eval-only";
      image-ipxe-install = "eval-only";
      image-raw-install-inmemory = "eval-only";
      image-qcow2-install-inmemory = "eval-only";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "eval-only";
      image-personalize-iso = "eval-only";
      image-personalize-kexec = "eval-only";
      closure = "eval-only";
      closure-live = "eval-only";
    };
    plain = {
      image-raw = "eval-only";
      image-iso = "eval-only";
      image-qcow2 = "eval-only";
      image-kexec = "eval-only";
      image-ipxe = "eval-only";
      image-raw-install = "eval-only";
      image-qcow2-install = "eval-only";
      image-iso-install = "eval-only";
      image-kexec-install = "eval-only";
      image-ipxe-install = "eval-only";
      image-raw-install-inmemory = "eval-only";
      image-qcow2-install-inmemory = "eval-only";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "eval-only";
      image-personalize-iso = "eval-only";
      image-personalize-kexec = "eval-only";
      closure = "eval-only";
      closure-live = "eval-only";
    };
    # The image delivery: no install script, so the installers carry this host's own disk
    # image and write it as it is.
    "image-install" = {
      image-raw = "eval-only";
      image-iso = "eval-only";
      image-qcow2 = "eval-only";
      image-kexec = "eval-only";
      image-ipxe = "eval-only";
      image-raw-install = "eval-only";
      image-qcow2-install = "eval-only";
      image-iso-install = "eval-only";
      image-kexec-install = "booted";
      image-ipxe-install = "eval-only";
      image-raw-install-inmemory = "eval-only";
      image-qcow2-install-inmemory = "eval-only";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "eval-only";
      image-personalize-iso = "eval-only";
      image-personalize-kexec = "booted";
      closure = "eval-only";
      closure-live = "eval-only";
    };

    "ext4-install" = {
      image-raw = "eval-only";
      image-iso = "eval-only";
      image-qcow2 = "eval-only";
      image-kexec = "eval-only";
      image-ipxe = "eval-only";
      image-raw-install = "eval-only";
      image-qcow2-install = "eval-only";
      image-iso-install = "eval-only";
      image-kexec-install = "booted";
      image-ipxe-install = "eval-only";
      image-raw-install-inmemory = "booted";
      image-qcow2-install-inmemory = "eval-only";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "booted";
      image-personalize-iso = "eval-only";
      image-personalize-kexec = "booted";
      closure = "booted";
      closure-live = "eval-only";
    };
  };

  bootedPairs = lib.sort lib.lessThan (lib.concatMap (h:
    map (n: "${h}.${n}")
      (lib.attrNames (lib.filterAttrs (_: s: s == "booted") table.${h})))
    (lib.attrNames table));
  witnessedPairs = lib.sort lib.lessThan (lib.unique witnessed);

  problems =
    lib.concatMap (h:
      let
        row = table.${h};
        missing = lib.subtractLists (lib.attrNames row) endpointSet;
        extra = lib.subtractLists endpointSet (lib.attrNames row);
        bad = lib.filterAttrs (_: s: !builtins.elem s statuses) row;
        declaredHoles = lib.attrNames (lib.filterAttrs (_: s: s == "hole") row);
        holeDrift =
          lib.subtractLists declaredHoles lawHoles.${h}
          ++ lib.subtractLists lawHoles.${h} declaredHoles;
      in
      lib.optional (missing != [ ]) "${h}: uncovered endpoints ${builtins.toJSON missing}"
      ++ lib.optional (extra != [ ]) "${h}: unknown endpoints ${builtins.toJSON extra}"
      ++ lib.optional (bad != { }) "${h}: unknown statuses ${builtins.toJSON bad}"
      ++ lib.optional (holeDrift != [ ])
        "${h}: holes drift from the laws ${builtins.toJSON holeDrift}")
      (lib.attrNames table)
    ++ lib.optional (bootedPairs != witnessedPairs)
      ("booted drifts from what the e2e suite witnesses:\n  unwitnessed booted: "
        + builtins.toJSON (lib.subtractLists witnessedPairs bootedPairs)
        + "\n  witnessed but not booted: "
        + builtins.toJSON (lib.subtractLists bootedPairs witnessedPairs));

  rendered = lib.concatMapStringsSep "\n" (h:
    lib.concatMapStringsSep "\n" (n: "${h}.${n} ${table.${h}.${n}}")
      (lib.attrNames table.${h}))
    (lib.attrNames table);
in

assert lib.assertMsg (problems == [ ])
  "the coverage table is incomplete or drifts:\n${lib.concatStringsSep "\n" problems}";

{
  inherit table endpointSet lawHoles;
  check = pkgs.writeText "test-coverage" rendered;
}
