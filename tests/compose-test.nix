# The composer over REAL hosts — eval-only. Every endpoint of every host is forced to a
# .drv (context discarded, so nothing is built): the layer that let two breakages ship was
# exactly the one nothing evaluated. The law and slot assertions run on the same real
# configurations. Building and booting is the e2e's job, not this one's.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;

  endpointNames = [
    "image-iso" "image-raw" "image-qcow2" "image-kexec" "image-ipxe"
    "image-iso-install" "image-raw-install" "image-qcow2-install"
    "image-kexec-install" "image-ipxe-install"
    "image-secrets-vfat" "image-secrets-iso" "image-secrets-json"
  ];

  force = e: name:
    builtins.unsafeDiscardStringContext
      (if lib.hasPrefix "image-secrets" name
       then e.${name}.file.drvPath
       else e.${name}.file.drvPath);

  # zfs: the runtime disk endpoints are the L2 hole; everything else must evaluate.
  holes = { zfs = [ "image-raw" "image-qcow2" ]; };
  expectedFor = h: lib.subtractLists (holes.${h} or [ ]) endpointNames;

  forcedFor = h:
    map (n: "${h}.${n} ${force (compose hosts.${h}) n}") (expectedFor h);

  refusedHoles = lib.concatMap (h:
    map (n: {
      case = "${h}.${n}";
      refused = !(builtins.tryEval (compose hosts.${h}).${n}.file.outPath).success;
    }) (holes.${h} or [ ])) (lib.attrNames hosts);

  e = compose hosts.ext4;
  plain = compose hosts.plain;
in

assert lib.assertMsg (e.image-iso.toplevel != e.image-raw.toplevel)
  "a real host's live variant is a different toplevel";
assert lib.assertMsg (e.closure-live == e.image-iso.toplevel)
  "#closure-live is a lookup of what image packed";
assert lib.assertMsg (e.image-raw.slot != null)
  "embedded delivery on a real host composes a slot";
assert lib.assertMsg (plain.image-raw.slot == null)
  "no secrets declared: a silent no-op everywhere, no slot anywhere";
assert lib.assertMsg (lib.all (r: r.refused) refusedHoles)
  "L2 holes must refuse at eval on a real zfs host: ${builtins.toJSON refusedHoles}";

pkgs.writeText "test-hosts-compose"
  (lib.concatMapStringsSep "\n" (h: lib.concatStringsSep "\n" (forcedFor h))
    (lib.attrNames hosts))
