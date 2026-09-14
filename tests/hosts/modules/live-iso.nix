# The live-ISO VARIANT: the composer applies this over the host's own configuration for the
# iso format. The root is a tmpfs, the medium is found by the LABEL the composer derived
# from the artifact's name (tools/ids is the agreement point — the iso part derives the
# same volid from the same name), and the store is the squashfs INSIDE the medium,
# loop-mounted read-only. The registration unit rides along, because a configuration that
# says /nix/store is read-only does not work without it.
#
# This replaces the nixos-generators live path: no generator, no iso-image module — the
# artifact face is the image block's xorriso assembly, this is only its runtime face.
{ label }:
{ lib, config, pkgs, ... }:
let
  # /sysroot when stage 1 is systemd's: the loop's backing file lives in the initrd
  # namespace, and the prefix is also what orders the mounts — RequiresMountsFor on the
  # What path makes the squashfs wait for the medium.
  sysroot = lib.optionalString config.boot.initrd.systemd.enable "/sysroot";
in
{
  fileSystems = lib.mkForce {
    "/" = {
      device = "none";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };
    "/iso" = {
      device = "/dev/disk/by-label/${label}";
      fsType = "iso9660";
      options = [ "ro" ];
      neededForBoot = true;
    };
    "/nix/store" = {
      device = "${sysroot}/iso/nix-store.squashfs";
      fsType = "squashfs";
      options = [ "loop" "ro" ];
      neededForBoot = true;
    };
  };
  boot.initrd.kernelModules = [ "loop" ];
  boot.initrd.availableKernelModules = [ "iso9660" "squashfs" ];
  # The medium carries the bootloader; the system installs none.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.kernelParams = [ "boot.live" ];
  boot.postBootCommands = ''
    if [ -e /nix/store/nix-path-registration ] && [ ! -e /nix/var/nix/db/db.sqlite ]; then
      ${pkgs.nix}/bin/nix-store --load-db < /nix/store/nix-path-registration
    fi
  '';
}
