# A sidecar's identity has to agree in THREE places, or a host mounts by a label the medium
# does not carry: what a host config derives AHEAD of the build (builder.lib.labels, a pure
# function of the name), what the block hands back (out.label / out.volumeId), and what blkid
# reads off the built medium. The first is the one real usage exercises and the suite used to
# skip — a host knows the label only by deriving it, never by reading the artifact it is about
# to mount. This asserts all three are the same string.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  labels = (import ../lib/api.nix).labels;
  e = compose hosts.ext4;
  name = hosts.ext4.name;
  vfat = e.image-secrets-vfat;
  iso = e.image-secrets-iso;

  # What a host CONFIG would derive, with no artifact in hand.
  derivedVfatLabel = labels.secretsVfatLabel;
  derivedVolumeId = labels.secretsVolumeId name;
  derivedIsoLabel = labels.secretsIsoLabel name;

  # The FAT serial as blkid prints it back: XXXX-XXXX, uppercase.
  fatUuid =
    let v = lib.toUpper derivedVolumeId;
    in "${lib.substring 0 4 v}-${lib.substring 4 4 v}";
in
# The block must hand back exactly what a host derives — the seed lives in one place now, so
# this pins that it stays that way.
assert lib.assertMsg (derivedVfatLabel == vfat.label && derivedVolumeId == vfat.volumeId)
  "host-derived vfat identity must equal what the block hands back";
assert lib.assertMsg (derivedIsoLabel == iso.label)
  "host-derived iso label must equal what the block hands back";
pkgs.runCommand "test-sidecar-identity"
  { nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils ]; }
  ''
    set -euo pipefail

    ${lib.getExe vfat.run} side.img
    ${lib.getExe iso.run} side.iso

    echo "== what blkid reads off the medium equals what a host DERIVES, not just what the block returns =="
    vlabel=$(blkid -o value -s LABEL side.img)
    vuuid=$(blkid -o value -s UUID side.img)
    [ "$vlabel" = ${lib.escapeShellArg derivedVfatLabel} ] \
      || { echo "vfat label: medium '$vlabel', host derives '${derivedVfatLabel}'" >&2; exit 1; }
    [ "$vuuid" = ${lib.escapeShellArg fatUuid} ] \
      || { echo "vfat uuid: medium '$vuuid', host derives '${fatUuid}'" >&2; exit 1; }

    ilabel=$(blkid -o value -s LABEL side.iso)
    [ "$ilabel" = ${lib.escapeShellArg derivedIsoLabel} ] \
      || { echo "iso label: medium '$ilabel', host derives '${derivedIsoLabel}'" >&2; exit 1; }

    echo "sidecar identities agree across derive / return / stamp:" >&2
    echo "  vfat: label=$vlabel uuid=$vuuid" >&2
    echo "  iso:  label=$ilabel" >&2
    touch "$out"
  ''
