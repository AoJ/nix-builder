# A zfs server. The configuration states a zfs root, and that is enough for the front door
# to know the storage and the pool (`rpool/root` → `rpool`). What it cannot read is how to
# CREATE that pool — a pool is not a disko layout — so this host states its own install
# recipe: create-and-mount, and mount-an-existing (the never-reformat path).
#
# Because the pool is created by the install (law L2), this host has no runtime disk
# image: `image-raw` refuses, and the deliverables are the installers. See README.md.
{ pkgs, builder }:

let
  device = "/dev/disk/by-id/virtio-main";
  pool = "rpool";

  configuration = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-zfs";
    users.allowNoPasswordLogin = true;

    networking.hostId = "8425e349";
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    fileSystems."/" = { device = "${pool}/root"; fsType = "zfs"; };
    fileSystems."/boot" = { device = "/dev/disk/by-partlabel/ESP"; fsType = "vfat"; };
    boot.loader.systemd-boot.enable = true;
  };

  host = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [ configuration ];
  };
in
builder.lib.imagesFor {
  inherit pkgs host;
  slotName = "secrets";

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
    keyDestination = "/var/lib/sops/age.key";
    # The disks a create may clear. With a disko layout this comes from the layout; a
    # hand-written pool has to say it, and this is the only place that says it.
    disks = [ device ];

    # Both scripts run under the install action's PATH — nix, zfs, util-linux, coreutils —
    # so anything outside that set is spelled absolutely.
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
