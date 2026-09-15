# The iso RUNTIME face: the medium found by the LABEL both sides derive from one artifact
# name through the ids tool, a tmpfs root, and the read-only store overlaid out of the
# squashfs inside the medium (the shared roStore). Entries use nixpkgs' image-media
# priority (60), so the face overrides a host's disk declarations without a fight — L1 as a
# priority. Shared by the live-iso variant and the iso-rooted installer.
{ pkgs }:
{ label }:
{ lib, config, ... }@args:

let
  media = lib.mkOverride 60;
  roStore = import ./ro-store.nix { inherit pkgs; };
in
lib.mkMerge [
  (roStore args {
    device = "/iso/nix-store.squashfs";
    fsType = "squashfs";
    options = [ "loop" "ro" ];
    sysrootPrefixed = true;
  })
  {
    fileSystems."/" = media {
      device = "none";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };
    fileSystems."/iso" = media {
      device = "/dev/disk/by-label/${label}";
      fsType = "iso9660";
      options = [ "ro" ];
      neededForBoot = true;
    };
    boot.initrd.availableKernelModules = [ "iso9660" ];
  }
]
