# The (host, endpoint) coverage table. Every pair carries exactly ONE declared status, so
# "it only evaluates" is a visible name, never a default the suite quietly hands out:
#
#   booted     an e2e boots the artifact (or, for phase 2, runs it against one) and reads
#              the witness off the running system
#   built      a suite builds and probes the artifact for this host
#   hole       refused at eval by a law — asserted red, not skipped
#   eval-only  forced to a .drv and NOTHING more; a named debt, not a proof
#
# The suite fails if the table is incomplete against the endpoint set, if a status is not
# one of the four, or if the holes do not match the laws exactly.
{ pkgs }:

let
  inherit (pkgs) lib;

  endpointSet = [
    "image-iso" "image-raw" "image-qcow2" "image-kexec" "image-ipxe"
    "image-iso-install" "image-raw-install" "image-qcow2-install"
    "image-kexec-install" "image-ipxe-install"
    "image-secrets-vfat" "image-secrets-iso" "image-secrets-json"
    "image-personalize" "image-personalize-iso"
    "closure" "closure-live"
  ];

  statuses = [ "booted" "built" "hole" "eval-only" ];

  # The holes the LAWS derive: the memory-rooted installer does not exist (every host),
  # and a zfs host's runtime disk endpoints are L2.
  memoryInstallHoles = [ "image-iso-install" "image-kexec-install" "image-ipxe-install" ];
  lawHoles = {
    ext4 = memoryInstallHoles;
    memory = memoryInstallHoles;
    plain = memoryInstallHoles;
    zfs = memoryInstallHoles ++ [ "image-raw" "image-qcow2" ];
  };

  table = {
    ext4 = {
      image-raw = "booted";
      image-iso = "booted";
      image-qcow2 = "eval-only";
      image-kexec = "eval-only";
      image-ipxe = "eval-only";
      image-raw-install = "eval-only";
      image-qcow2-install = "eval-only";
      image-iso-install = "hole";
      image-kexec-install = "hole";
      image-ipxe-install = "hole";
      image-secrets-vfat = "booted";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "booted";
      image-personalize-iso = "booted";
      closure = "booted";
      closure-live = "booted";
    };
    memory = {
      image-raw = "booted";
      image-iso = "eval-only";
      image-qcow2 = "eval-only";
      image-kexec = "eval-only";
      image-ipxe = "eval-only";
      image-raw-install = "eval-only";
      image-qcow2-install = "eval-only";
      image-iso-install = "hole";
      image-kexec-install = "hole";
      image-ipxe-install = "hole";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "eval-only";
      image-personalize-iso = "eval-only";
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
      image-iso-install = "hole";
      image-kexec-install = "hole";
      image-ipxe-install = "hole";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "booted";
      image-personalize-iso = "eval-only";
      closure = "booted";
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
      image-iso-install = "hole";
      image-kexec-install = "hole";
      image-ipxe-install = "hole";
      image-secrets-vfat = "eval-only";
      image-secrets-iso = "eval-only";
      image-secrets-json = "eval-only";
      image-personalize = "eval-only";
      image-personalize-iso = "eval-only";
      closure = "eval-only";
      closure-live = "eval-only";
    };
  };

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
      (lib.attrNames table);

  rendered = lib.concatMapStringsSep "\n" (h:
    lib.concatMapStringsSep "\n" (n: "${h}.${n} ${table.${h}.${n}}")
      (lib.attrNames table.${h}))
    (lib.attrNames table);
in

assert lib.assertMsg (problems == [ ])
  "the coverage table is incomplete or drifts from the laws:\n${lib.concatStringsSep "\n" problems}";

{
  inherit table endpointSet lawHoles;
  check = pkgs.writeText "test-coverage" rendered;
}
