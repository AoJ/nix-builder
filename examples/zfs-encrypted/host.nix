# An encrypted zfs host — the plain zfs example plus this host's own unlock story.
# Encryption follows the install (law L3): no image is ever encrypted, and the pool is
# created at install time with the real passphrase.
#
# Notice what blocks does NOT know here. It carries a file this host called `pool.pass`
# into the slot and never opens it; this host's own scripts read it, off the path the
# builder publishes (`builder.lib.paths.installSlot`) while the install runs. Where the
# passphrase then lives on the installed machine, and how stage 1 gets at it, is this
# host's layout — the slot partition, mounted where it likes.
{ pkgs, builder }:

let
  device = "/dev/disk/by-id/virtio-main";
  pool = "rpool";
  slotName = "secrets";
  # Published by the builder: where the install action lays the slot out while it runs.
  inherit (builder.lib.paths) installSlot;
  # This host's own choices: where its slot partition mounts once installed, and the
  # initrd path stage 1 reads the passphrase from.
  slotMount = "/var/lib/slot";
  poolKeyInitrd = "/pool.key";

  configuration = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-zfs-enc";
    users.allowNoPasswordLogin = true;

    networking.hostId = "1badb002";
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    fileSystems."/" = { device = "${pool}/root"; fsType = "zfs"; };
    fileSystems."/boot" = { device = "/dev/disk/by-partlabel/ESP"; fsType = "vfat"; };
    boot.loader.systemd-boot.enable = true;

    # The slot the install filled, mounted where this host wants it.
    fileSystems.${slotMount} = {
      device = "/dev/disk/by-partlabel/${slotName}";
      fsType = "vfat";
      options = [ "ro" "umask=0077" ];
    };
    # The bootloader step copies the passphrase into the initrd at every generation, so
    # stage 1 can read it before the pool unlocks — and it therefore sits in plaintext on
    # the ESP. Whether that is protection enough is this host's call.
    boot.initrd.secrets.${poolKeyInitrd} = "${slotMount}/pool.pass";
  };

  host = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [ configuration ];
  };
in
builder.lib.imagesFor {
  inherit pkgs host slotName;

  # The passphrase is ONE MORE FILE in the same delivery — the bricks combine, and blocks
  # learns nothing about what either file is for.
  secrets = {
    delivery = [ "embedded" "sidecar" ];
    files = [
      { target = "/sops.age"; content.file = "/run/secrets/example-zfs-enc/host.key"; }
      { target = "/pool.pass"; content.file = "/run/secrets/example-zfs-enc/pool.pass"; }
    ];
  };

  install = {
    disks = [ device ];
    # Not decoration: it makes an installer whose slot never received the declared files
    # refuse BEFORE any wipe, instead of failing the create with the disk already cleared.
    encrypted = true;

    # The layout: an ESP, the SLOT partition this host reads its secrets from, and the
    # pool. The create takes the passphrase off the published install-slot path, then
    # repoints keylocation at the initrd file the installed system will have.
    script = pkgs.writeShellScript "prepare-zfs-enc" ''
      set -euo pipefail
      disk=${device}
      ${pkgs.gptfdisk}/bin/sgdisk -Z "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 2:0:+8M -t 2:8300 -c 2:${slotName} "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 3:0:0 -t 3:bf01 -c 3:zfs "$disk"
      ${pkgs.systemd}/bin/udevadm settle
      ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n ESP "''${disk}-part1"
      ${pkgs.dosfstools}/bin/mkfs.fat -n SLOT "''${disk}-part2"
      zpool create -f -o ashift=12 -O mountpoint=none -O compression=on \
        -O encryption=on -O keyformat=passphrase \
        -O keylocation=file://${installSlot}/pool.pass ${pool} "''${disk}-part3"
      zfs set keylocation=file://${poolKeyInitrd} ${pool}
      zfs create -o mountpoint=legacy ${pool}/root
      mkdir -p /mnt
      mount -t zfs ${pool}/root /mnt
      mkdir -p /mnt/boot
      mount "''${disk}-part1" /mnt/boot
    '';

  };
}
