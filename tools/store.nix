{ pkgs, bashTool, registrationPath }:

{ name, rootPaths, shape, label, profile ? null }:

let
  inherit (pkgs) lib;
  ids = import ./ids.nix;

  closure = pkgs.closureInfo { rootPaths = rootPaths; };

  # The file the store dump sits at, from the ONE constant: a nixpkgs convention
  # (nixos/lib/make-squashfs.nix), loaded back by the register unit at the same path.
  registrationFile = baseNameOf registrationPath;

  uuid = ids.uuid "${name}:store";

  ext4Tool = bashTool {
    name = "store-ext4";
    runtimeInputs = [
      pkgs.coreutils pkgs.findutils pkgs.gawk pkgs.e2fsprogs pkgs.fakeroot
      pkgs.nix pkgs.sqlite
    ];
    text = builtins.readFile ./store-ext4.sh;
  };

  ext4 = pkgs.runCommand "store-ext4.img" { }
    ''
      ${ext4Tool}/bin/store-ext4 "$out" ${lib.escapeShellArg label} \
        ${lib.escapeShellArg uuid} ${closure}/registration ${closure}/store-paths \
        ${lib.optionalString (profile != null) "${profile}"}
    '';

  squashfs = pkgs.runCommand "store-squashfs.img"
    { nativeBuildInputs = [ pkgs.squashfsTools pkgs.coreutils ]; }
    ''
      set -euo pipefail
      # A read-only store cannot hold the database — it lives at /nix/var/nix/db, which
      # boots empty. So the image carries the DUMP and a unit in the OS loads it at every
      # boot. That unit is not this tool's to give.
      cp ${closure}/registration ${registrationFile}
      mksquashfs ${registrationFile} $(cat ${closure}/store-paths) "$out" \
        -no-hardlinks -keep-as-directory -all-root -b 1048576 -comp zstd \
        -no-progress
    '';
in
{
  img = { inherit ext4 squashfs; }.${shape};
  fs = shape;
  needsBootUnit = shape != "ext4";
  inherit uuid registrationPath;
}
