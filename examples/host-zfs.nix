# The zfs server — the install story. A zfs pool is created by the install, never by the
# image (law L2), so this host's deliverables are the -install wrappers; `image-raw` and
# `image-qcow2` REFUSE at eval as named holes. Three installers of the same host:
#
#   image-kexec-install           what a deploy kexecs into the running machine
#   image-raw-install             a USB stick installing a DIFFERENT disk (disk-rooted:
#                                 the medium carries the closure RAM-independently)
#   image-raw-install-inmemory    memory-rooted: the closure rides the initrd, the booted
#                                 installer holds no claim on any disk — the boot medium
#                                 itself is a valid target (the one-disk cloud box)
#
# A reinstall over an existing target is an EXPLICIT act: `install.wipe` as an exact word
# on the installer's kernel command line — the loader channel a deploy controls. Without
# it, a present target is mounted, never reformatted.
{ pkgs, tools, compose }:

let
  system = "x86_64-linux";
  slotName = "secrets";
  device = "/dev/disk/by-id/virtio-main";

  base = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-zfs";
    users.allowNoPasswordLogin = true;
    # The zfs layout is the host's own declaration; the pool is created at install.
    networking.hostId = "8425e349";
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    fileSystems."/" = { device = "rpool/root"; fsType = "zfs"; };
    fileSystems."/boot" = { device = "/dev/disk/by-partlabel/ESP"; fsType = "vfat"; };
    boot.loader.systemd-boot.enable = true;
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
    name = "example-zfs";
    inherit system slotName;
    variants = {
      runtime = extract nixos // { storage = "zfs"; };
      liveNetboot = extract liveNetboot;
      liveIso = label: extract (nixos.extendModules {
        modules = [ (import ../tests/hosts/modules/live-iso.nix { inherit label; face = tools.isoFace; }) ];
      });
    };
    secrets = {
      delivery = [ "embedded" "sidecar" ];
      bundle = "${fixture}/bundle.yaml";
      keyTarget = "/sops.age";
      files = [{
        target = "/sops.age";
        source = "${fixture}/host.key";
        runtimeSource = "${fixture}/host.key";
      }];
    };
    # The extracted install values: prepare creates the pool AND mounts it at /mnt (the
    # disko-script role); mount handles the already-present pool — the never-reformat
    # path. Both run under the install action's PATH (nix, zfs, util-linux, coreutils);
    # anything outside that set is spelled absolutely.
    install = {
      pool = "rpool";
      encrypted = false;
      keyDestination = "/var/lib/sops/age.key";
      poolKeyDestination = null;
      disks = [ device ];
      report = null;
      prepare = pkgs.writeShellScript "prepare-zfs" ''
        set -euo pipefail
        disk=${device}
        ${pkgs.gptfdisk}/bin/sgdisk -Z "$disk"
        ${pkgs.gptfdisk}/bin/sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP "$disk"
        ${pkgs.gptfdisk}/bin/sgdisk -n 2:0:0 -t 2:bf01 -c 2:zfs "$disk"
        ${pkgs.systemd}/bin/udevadm settle
        ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n ESP "''${disk}-part1"
        zpool create -f -o ashift=12 -O mountpoint=none -O compression=on \
          rpool "''${disk}-part2"
        zfs create -o mountpoint=legacy rpool/root
        mkdir -p /mnt
        mount -t zfs rpool/root /mnt
        mkdir -p /mnt/boot
        mount "''${disk}-part1" /mnt/boot
      '';
      mount = pkgs.writeShellScript "mount-zfs" ''
        set -euo pipefail
        zpool import rpool
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
    image-raw-install = endpoints.image-raw-install.file;
    image-raw-install-inmemory = endpoints.image-raw-install-inmemory.file;
    # Phase 2 for a zfs host binds to the -install artifact (its runtime disk endpoints
    # are the L2 holes) — the composer picks that for you.
    image-personalize = endpoints.image-personalize.run;
    closure = endpoints.closure;
  };
}
