# An encrypted zfs host — the plain zfs example plus the key's whole path. Encryption
# follows the install (law L3): no image is ever encrypted, and the pool is created at
# install time with the REAL passphrase, delivered like any other secret.
#
# Three declarations have to agree, and they are bound here through two values:
#   pool.pass in secrets.files   the passphrase rides the same delivery as the host key;
#                                an installer without it REFUSES before any wipe
#   install.poolKeyDestination   where the act delivers it on the target
#   keylocation + initrd secret  what stage 1 reads to unlock, unattended
#
# See README.md for the seven steps from vault to unlock.
{ pkgs, builder }:

let
  device = "/dev/disk/by-id/virtio-main";
  pool = "rpool";
  # The two ends of the key's journey on the target: where the install puts it, and the
  # path inside the initrd that the pool's keylocation names.
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

    # The bootloader step copies this into the initrd at every generation, so the key is
    # readable before the pool unlocks — and therefore sits in plaintext on the ESP.
    # Whether that is protection enough is this host's call.
    boot.initrd.secrets.${poolKeyInitrd} = poolKeyTarget;
  };

  host = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [ configuration ];
  };
in
builder.lib.imagesFor {
  inherit pkgs host;
  slotName = "secrets";

  # The passphrase is ONE MORE FILE in the same delivery — the bricks combine, there is no
  # special channel for install-time secrets.
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
    keyDestination = "/var/lib/sops/age.key";
    disks = [ device ];
    # Not decoration: it makes an installer that was never given the passphrase refuse
    # BEFORE any wipe, instead of failing the create with the disk already cleared.
    encrypted = true;
    poolKeyDestination = poolKeyTarget;

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
