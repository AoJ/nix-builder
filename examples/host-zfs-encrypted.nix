# The encrypted zfs host — the whole key story on top of host-zfs.nix. Encryption is a
# property of the storage layout and follows the install (law L3): no image is ever
# encrypted, the pool is created at install with the REAL passphrase, delivered like any
# other secret. Nothing is generated on the target; nothing rides the store.
#
# Three bindings make the unattended unlock, all declared HERE, by the host:
#   pool.pass in the slot        -> the installer reads it; the create consumes it, and an
#                                   install without it is REFUSED before any wipe
#   poolKeyDestination           -> the action delivers a copy onto the installed system
#   keylocation + initrd secret  -> the layout points the pool at a file the initrd
#                                   carries, sourced from that destination — stage 1
#                                   unlocks with it, no prompt anywhere
{ pkgs, tools, compose }:

let
  system = "x86_64-linux";
  slotName = "secrets";
  device = "/dev/disk/by-id/virtio-main";
  poolKeyTarget = "/var/keys/pool.key";
  poolKeyInitrd = "/pool.key";

  base = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-zfs-enc";
    users.allowNoPasswordLogin = true;
    networking.hostId = "1badb002";
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    fileSystems."/" = { device = "rpool/root"; fsType = "zfs"; };
    fileSystems."/boot" = { device = "/dev/disk/by-partlabel/ESP"; fsType = "vfat"; };
    boot.loader.systemd-boot.enable = true;
    # The delivered key, carried into the initrd at bootloader install — this is what
    # stage 1 reads before the pool unlocks. It sits plaintext on the ESP by design;
    # whether that is protection enough is the host's call (see the design's secrets
    # section) — a host needing more changes its delivery, not this mechanism.
    boot.initrd.secrets.${poolKeyInitrd} = poolKeyTarget;
  };

  nixos = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [ base ];
  };
  liveNetboot = nixos.extendModules {
    modules = [ (import ../tests/hosts/modules/live-netboot.nix { face = tools.netbootFace; }) ];
  };

  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
  extract = import ../tests/extract.nix;

  host = {
    name = "example-zfs-enc";
    inherit system slotName;
    variants = {
      runtime = extract nixos // { storage = "zfs"; };
      liveNetboot = extract liveNetboot;
      liveIso = label: extract (nixos.extendModules {
        modules = [ (import ../tests/hosts/modules/live-iso.nix { inherit label; face = tools.isoFace; }) ];
      });
    };
    # The pool passphrase is ONE MORE FILE riding the same embedded delivery — the bricks
    # combine, no special channel.
    secrets = {
      delivery = [ "embedded" "sidecar" ];
      bundle = "${fixture}/bundle.yaml";
      keyTarget = "/sops.age";
      files = [
        {
          target = "/sops.age";
          source = "${fixture}/host.key";
          runtimeSource = "${fixture}/host.key";
        }
        {
          target = "/pool.pass";
          source = "${fixture}/pool.pass";
          runtimeSource = "${fixture}/pool.pass";
        }
      ];
    };
    install = {
      pool = "rpool";
      encrypted = true;
      keyDestination = "/var/lib/sops/age.key";
      poolKeyDestination = poolKeyTarget;
      disks = [ device ];
      report = null;
      # The create consumes the delivered passphrase (the installer places it at
      # /tmp/zfs_root_key), then points keylocation at the initrd path — the file the
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
          -O keylocation=file:///tmp/zfs_root_key rpool "''${disk}-part2"
        zfs set keylocation=file://${poolKeyInitrd} rpool
        zfs create -o mountpoint=legacy rpool/root
        mkdir -p /mnt
        mount -t zfs rpool/root /mnt
        mkdir -p /mnt/boot
        mount "''${disk}-part1" /mnt/boot
      '';
      # The never-reformat path over an encrypted pool: import, load the delivered key
      # (the on-disk keylocation names the initrd file, absent in the installer), mount.
      mount = pkgs.writeShellScript "mount-zfs-enc" ''
        set -euo pipefail
        zpool import rpool
        zfs load-key -L file:///tmp/zfs_root_key rpool
        mkdir -p /mnt
        mount -t zfs rpool/root /mnt
        mkdir -p /mnt/boot
        mount ${device}-part1 /mnt/boot
      '';
    };
  };

  endpoints = compose host;
in
{
  inherit host endpoints;
  shown = {
    image-kexec-install = endpoints.image-kexec-install.file;
    image-personalize-kexec = endpoints.image-personalize-kexec.run;
    closure = endpoints.closure;
  };
}
