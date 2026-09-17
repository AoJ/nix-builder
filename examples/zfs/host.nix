# The zfs server — the install story. A zfs pool is created by the install, never by the
# image (law L2), so this host's deliverables are the -install wrappers; asking for
# `image-raw` or `image-qcow2` REFUSES at eval as a named hole.
#
# Three installers of the SAME host, and which one an operation uses is the deploy's
# call, not a property of the host:
#   image-kexec-install         what a deploy kexecs into a running machine
#   image-raw-install           disk-rooted: a USB stick installing a DIFFERENT disk,
#                               carrying the closure RAM-independently
#   image-raw-install-inmemory  memory-rooted: the closure rides the initrd, the booted
#                               installer holds no claim on any disk — so the boot
#                               medium itself is a valid target (the one-disk cloud box)
#
# Reinstall over an existing target is an EXPLICIT act: `install.wipe` as an exact word
# on the installer's kernel command line, the loader channel a deploy controls. Without
# it a present pool is mounted, never reformatted.
{ pkgs, builder }:

let
  inherit (builder.lib.mk { inherit pkgs; }) modules;
  inherit (builder.lib) extract;

  system = "x86_64-linux";
  slotName = "secrets";
  device = "/dev/disk/by-id/virtio-main";
  pool = "rpool";

  configuration = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-zfs";
    users.allowNoPasswordLogin = true;

    # The zfs layout is the host's own declaration; the pool itself appears at install.
    networking.hostId = "8425e349";
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    fileSystems."/" = { device = "${pool}/root"; fsType = "zfs"; };
    fileSystems."/boot" = { device = "/dev/disk/by-partlabel/ESP"; fsType = "vfat"; };
    boot.loader.systemd-boot.enable = true;
  };

  nixos = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [ configuration ];
  };
in
{
  name = "example-zfs";
  inherit system slotName;

  variants = {
    runtime = extract nixos // { storage = "zfs"; };
    liveNetboot = extract (nixos.extendModules { modules = [ modules.liveNetboot ]; });
    liveIso = label: extract (nixos.extendModules { modules = [ (modules.liveIso label) ]; });
  };

  secrets = {
    delivery = [ "embedded" "sidecar" ];
    bundle = "/run/secrets/example-zfs/bundle.yaml";
    keyTarget = "/sops.age";
    files = [{
      target = "/sops.age";
      source = "/run/secrets/example-zfs/host.key";
      runtimeSource = "/run/secrets/example-zfs/host.key";
    }];
  };

  install = {
    inherit pool;
    encrypted = false;
    keyDestination = "/var/lib/sops/age.key";
    poolKeyDestination = null;
    disks = [ device ];
    report = null;

    # prepare creates the pool AND mounts it at /mnt (disko's create+mount role, by hand
    # here because a pool is not a disko layout). It runs under the install action's PATH
    # — nix, zfs, util-linux, coreutils — so anything outside that set is spelled
    # absolutely.
    prepare = pkgs.writeShellScript "prepare-zfs" ''
      set -euo pipefail
      disk=${device}
      ${pkgs.gptfdisk}/bin/sgdisk -Z "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 2:0:0 -t 2:bf01 -c 2:zfs "$disk"
      ${pkgs.systemd}/bin/udevadm settle
      ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n ESP "''${disk}-part1"
      zpool create -f -o ashift=12 -O mountpoint=none -O compression=on \
        ${pool} "''${disk}-part2"
      zfs create -o mountpoint=legacy ${pool}/root
      mkdir -p /mnt
      mount -t zfs ${pool}/root /mnt
      mkdir -p /mnt/boot
      mount "''${disk}-part1" /mnt/boot
    '';

    # The never-reformat path: the pool is already there, so just mount it.
    mount = pkgs.writeShellScript "mount-zfs" ''
      set -euo pipefail
      zpool import ${pool}
      mkdir -p /mnt
      mount -t zfs ${pool}/root /mnt
      mkdir -p /mnt/boot
      mount ${device}-part1 /mnt/boot
    '';
  };
}
