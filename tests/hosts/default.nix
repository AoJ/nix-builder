# REAL hosts for the composer: each is an evaluated nixosSystem, and the composer's host
# record is produced by the one explicit extraction. The set spans the dimensions — disk vs
# memory, ext4 vs squashfs vs zfs, secrets delivered vs none — because that is what a
# hand-assembled record cannot prove.
{ pkgs, tools }:

let
  fixture = import ../../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
  extract = import ../extract.nix;

  evalHost = system: modules:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit system modules;
    };

  syntheticInstall = {
    prepare = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
    mount = pkgs.writeShellScript "mount" "mount /dev/target-root \"$1\"";
    pool = "rpool";
    keyDestination = "/var/lib/sops/age.key";
  };

  # The zfs host's REAL extracted install values: its disk-preparation creates the pool
  # (and mounts it — the diskoScript role), its mount handles the already-present pool
  # (the never-reformat path). The target disk is named here because these values are the
  # host's own; nothing generic knows it.
  zfsInstall = {
    pool = "rpool";
    keyDestination = "/var/lib/sops/age.key";
    # Runs under the install action's PATH (nix, zfs, util-linux, coreutils); anything
    # outside that set is spelled absolutely. The target is named by the STABLE identity
    # the e2e attaches it with (a virtio serial), so the same extracted values work under
    # every wrapper — a disk-rooted installer shifts /dev/vdX, an identity does not.
    prepare = pkgs.writeShellScript "prepare-zfs" ''
      set -euo pipefail
      disk=/dev/disk/by-id/virtio-target
      ${pkgs.gptfdisk}/bin/sgdisk -Z "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 2:0:0 -t 2:bf01 -c 2:zfs "$disk"
      ${pkgs.systemd}/bin/udevadm settle
      ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n ESP "''${disk}-part1"
      zpool create -f -o ashift=12 -O mountpoint=none -O compression=on rpool "''${disk}-part2"
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
      mount /dev/disk/by-id/virtio-target-part1 /mnt/boot
    '';
  };

  # L3 in practice: the pool is created encrypted with the passphrase the slot delivered —
  # one more file riding the same embedded delivery (DECIDED: the bricks combine). The
  # witness line is read back by the encrypted-install e2e.
  zfsEncInstall = zfsInstall // {
    prepare = pkgs.writeShellScript "prepare-zfs-enc" ''
      set -euo pipefail
      disk=/dev/disk/by-id/virtio-target
      ${pkgs.gptfdisk}/bin/sgdisk -Z "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 2:0:0 -t 2:bf01 -c 2:zfs "$disk"
      ${pkgs.systemd}/bin/udevadm settle
      ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n ESP "''${disk}-part1"
      zpool create -f -o ashift=12 -O mountpoint=none -O compression=on \
        -O encryption=on -O keyformat=passphrase \
        -O keylocation=file:///tmp/zfs_root_key rpool "''${disk}-part2"
      echo "E2E-POOL-ENCRYPTION $(zfs get -H -o value encryption rpool)" > /dev/console
      zfs create -o mountpoint=legacy rpool/root
      mkdir -p /mnt
      mount -t zfs rpool/root /mnt
      mkdir -p /mnt/boot
      mount "''${disk}-part1" /mnt/boot
    '';
  };

  noSecrets = {
    delivery = [ ];
    files = [ ];
  };

  withSecrets = {
    delivery = [ "embedded" "sidecar" ];
    bundle = "${fixture}/bundle.yaml";
    keyTarget = "/sops.age";
    files = [{
      target = "/sops.age";
      source = "${fixture}/host.key";
      runtimeSource = "${fixture}/host.key";
    }];
  };

  mk = { name, modules, storage, secrets, install ? syntheticInstall,
         system ? "x86_64-linux" }:
    let
      runtime = evalHost system ([
        ./modules/base.nix
        ./modules/marker.nix
        { networking.hostName = name; }
      ] ++ modules);
      # The real extendModules step: each live variant is the host plus a face module,
      # evaluated by the composer's side of the world — never inside a block. There is one
      # variant per live format; no generic "live" fallback, so a missing one is an eval
      # error, not a silently wrong boot.
      liveNetboot = runtime.extendModules {
        modules = [ (import ./modules/live-netboot.nix { face = tools.netbootFace; }) ];
      };
    in
    {
      inherit name secrets system;
      variants = {
        runtime = extract runtime // { inherit storage; };
        liveNetboot = extract liveNetboot;
        # The iso's runtime face needs the medium's LABEL, which only the composer knows —
        # so this variant is a function the composer applies.
        liveIso = label: extract (runtime.extendModules {
          modules = [ (import ./modules/live-iso.nix { inherit label; face = tools.isoFace; }) ];
        });
      };
      inherit install;
    };
in
{
  ext4 = mk {
    name = "e2e-ext4";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = withSecrets;
  };

  memory = mk {
    name = "e2e-memory";
    modules = [ (import ./modules/read-only-store.nix {
      roStore = tools.roStore;
      device = "/dev/disk/by-partlabel/nixos";
    }) ];
    storage = "squashfs";
    secrets = noSecrets;
  };

  zfs = mk {
    name = "e2e-zfs";
    modules = [ ./modules/disk-zfs.nix ];
    storage = "zfs";
    secrets = withSecrets;
    install = zfsInstall;
  };

  zfs-enc = mk {
    name = "e2e-zfs-enc";
    modules = [ ./modules/disk-zfs.nix ];
    storage = "zfs";
    secrets = withSecrets // {
      files = withSecrets.files ++ [{
        target = "/pool.pass";
        source = "${fixture}/pool.pass";
        runtimeSource = "${fixture}/pool.pass";
      }];
    };
    install = zfsEncInstall;
  };

  plain = mk {
    name = "e2e-plain";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = noSecrets;
  };

  # The arch-split tripwire: a REAL aarch64 configuration, evaluated on this x86 box (pure
  # eval — nothing aarch64 is ever built here). The extraction must find the aa64 bootloader
  # in the TARGET's systemd and every endpoint must force to a .drv; building and booting
  # belongs to a builder with arm capacity.
  arm = mk {
    name = "e2e-arm";
    system = "aarch64-linux";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = withSecrets;
  };
}
