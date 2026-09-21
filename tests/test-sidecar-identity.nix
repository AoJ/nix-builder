# The block generates a sidecar's volume identity and now HANDS IT BACK (out.label,
# out.volumeId) so a consumer can mount by it. This proves the returned values are TRUE:
# it runs the vfat and iso sidecar runners and reads the identity blkid finds on the built
# medium, asserting it matches exactly what the block returned. A drift between what is
# stamped and what is reported is the whole failure this closes — a consumer mounting by a
# label the medium does not carry.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.ext4;
  vfat = e.image-secrets-vfat;
  iso = e.image-secrets-iso;
  # The FAT serial as blkid prints it back: XXXX-XXXX, uppercase.
  fatUuid =
    let v = lib.toUpper vfat.volumeId;
    in "${lib.substring 0 4 v}-${lib.substring 4 4 v}";
in
pkgs.runCommand "test-sidecar-identity"
  { nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils ]; }
  ''
    set -euo pipefail

    ${lib.getExe vfat.run} side.img
    ${lib.getExe iso.run} side.iso

    vlabel=$(blkid -o value -s LABEL side.img)
    vuuid=$(blkid -o value -s UUID side.img)
    [ "$vlabel" = ${lib.escapeShellArg vfat.label} ] \
      || { echo "vfat label: got '$vlabel', block returned '${vfat.label}'" >&2; exit 1; }
    [ "$vuuid" = ${lib.escapeShellArg fatUuid} ] \
      || { echo "vfat uuid: got '$vuuid', block's volumeId formats to '${fatUuid}'" >&2; exit 1; }

    ilabel=$(blkid -o value -s LABEL side.iso)
    [ "$ilabel" = ${lib.escapeShellArg iso.label} ] \
      || { echo "iso label: got '$ilabel', block returned '${iso.label}'" >&2; exit 1; }

    echo "sidecar identities match what the block hands back:" >&2
    echo "  vfat: label=$vlabel uuid=$vuuid" >&2
    echo "  iso:  label=$ilabel" >&2
    touch "$out"
  ''
