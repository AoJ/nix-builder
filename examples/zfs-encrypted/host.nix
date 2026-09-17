# The encrypted zfs host — the whole key story on top of the plain zfs example.
# Encryption is a property of the storage layout and follows the install (law L3): no
# image is ever encrypted, and the pool is created at install with the REAL passphrase.
#
# Three declarations make the unattended unlock, all of them the HOST's:
#   pool.pass in secrets.files   the passphrase rides the same embedded delivery as any
#                                other secret; the installer reads it from its slot. An
#                                install without it is REFUSED before any wipe — the
#                                create would otherwise fail after the disk was cleared.
#   poolKeyDestination           where the install DELIVERS the key onto the target.
#   keylocation + initrd secret  the layout points the pool at a file the initrd carries,
#                                sourced from that destination. Stage 1 unlocks with it —
#                                no prompt anywhere (full automation is the decision; a
#                                host wanting interactive unlock changes its layout).
#
# The fields, their types and what reads each: lib/host-record.nix — the contract the
# composer validates every record through.
{ pkgs, builder }:

let
  inherit (builder.lib.mk { inherit pkgs; }) modules;
  inherit (builder.lib) extract;

  system = "x86_64-linux";
  slotName = "secrets";
  device = "/dev/disk/by-id/virtio-main";
  pool = "rpool";

  # The two ends of the key's journey, named once: where the install puts it on the
  # target, and the path inside the initrd that the pool's keylocation names.
  poolKeyTarget = "/var/keys/pool.key";
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

    # The bootloader step copies this file into the initrd at every generation, so the
    # key is readable before the pool unlocks. It therefore sits in plaintext on the
    # ESP: whether that is protection enough is the host's call — a host needing more
    # changes its delivery or its layout, not this mechanism.
    boot.initrd.secrets.${poolKeyInitrd} = poolKeyTarget;
  };

  nixos = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [ configuration ];
  };
in
{
  name = "example-zfs-enc";
  inherit system slotName;

  variants = {
    runtime = extract nixos // { storage = "zfs"; };
    liveNetboot = extract (nixos.extendModules { modules = [ modules.liveNetboot ]; });
    liveIso = label: extract (nixos.extendModules { modules = [ (modules.liveIso label) ]; });
  };

  # The pool passphrase is ONE MORE FILE in the same delivery — the bricks combine, there
  # is no special channel for install-time secrets.
  secrets = {
    delivery = [ "embedded" "sidecar" ];
    bundle = "/run/secrets/example-zfs-enc/bundle.yaml";
    keyTarget = "/sops.age";
    files = [
      {
        target = "/sops.age";
        source = "/run/secrets/example-zfs-enc/host.key";
        runtimeSource = "/run/secrets/example-zfs-enc/host.key";
      }
      {
        target = "/pool.pass";
        source = "/run/secrets/example-zfs-enc/pool.pass";
        runtimeSource = "/run/secrets/example-zfs-enc/pool.pass";
      }
    ];
  };

  install = {
    inherit pool;
    encrypted = true;
    keyDestination = "/var/lib/sops/age.key";
    poolKeyDestination = poolKeyTarget;
    disks = [ device ];
    report = null;

    # The create consumes the delivered passphrase (the installer places it at
    # /tmp/zfs_root_key), then repoints keylocation at the initrd path — the file the
    # installed system's stage 1 will actually see.
    prepare = pkgs.writeShellScript "prepare-zfs-enc" ''
      set -euo pipefail
      disk=${device}
      ${pkgs.gptfdisk}/bin/sgdisk -Z "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 2:0:0 -t 2:bf01 -c 2:zfs "$disk"
      ${pkgs.systemd}/bin/udevadm settle
      ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n ESP "''${disk}-part1"
      zpool create -f -o ashift=12 -O mountpoint=none -O compression=on \
        -O encryption=on -O keyformat=passphrase \
        -O keylocation=file:///tmp/zfs_root_key ${pool} "''${disk}-part2"
      zfs set keylocation=file://${poolKeyInitrd} ${pool}
      zfs create -o mountpoint=legacy ${pool}/root
      mkdir -p /mnt
      mount -t zfs ${pool}/root /mnt
      mkdir -p /mnt/boot
      mount "''${disk}-part1" /mnt/boot
    '';

    # The never-reformat path over an encrypted pool: the on-disk keylocation names the
    # initrd file, which does not exist in the installer — so load the delivered key
    # explicitly, then mount.
    mount = pkgs.writeShellScript "mount-zfs-enc" ''
      set -euo pipefail
      zpool import ${pool}
      zfs load-key -L file:///tmp/zfs_root_key ${pool}
      mkdir -p /mnt
      mount -t zfs ${pool}/root /mnt
      mkdir -p /mnt/boot
      mount ${device}-part1 /mnt/boot
    '';
  };
}
