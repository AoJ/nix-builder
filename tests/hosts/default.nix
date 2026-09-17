# REAL hosts for the composer: each is an evaluated nixosSystem, and the composer's host
# record is produced by the one explicit extraction. The set spans the dimensions — disk vs
# memory, ext4 vs squashfs vs zfs, secrets delivered vs none — because that is what a
# hand-assembled record cannot prove.
{ pkgs, tools, record }:

let
  fixture = import ../../blocks/personalize/fixture.nix { inherit pkgs; };
  extract = import ../extract.nix;
  inherit (pkgs) lib;
  diskoModule = (import ../../disko-pin.nix) + "/module.nix";
  targetDevice = "/dev/disk/by-id/virtio-target";
  reportBin = "${record}/bin/e2e-record";
  # The encrypted host's unlock, one binding read in three places: the install delivers
  # the pool key to poolKeyTarget on the target, the initrd secret carries that file to
  # poolKeyInitrd inside the initrd, and the pool's keylocation names poolKeyInitrd — so
  # stage 1 loads the key from a file that exists exactly when it runs.
  poolKeyTarget = "/var/keys/pool.key";
  poolKeyInitrd = "/pool.key";

  evalHost = system: modules:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit system modules;
    };

  syntheticInstall = {
    prepare = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
    mount = pkgs.writeShellScript "mount" "mount /dev/target-root \"$1\"";
    pool = "rpool";
    encrypted = false;
    keyDestination = "/var/lib/sops/age.key";
    poolKeyDestination = null;
    disks = [ "/dev/target" ];
    report = null;
  };

  # The zfs host's REAL extracted install values: its disk-preparation creates the pool
  # (and mounts it — the diskoScript role), its mount handles the already-present pool
  # (the never-reformat path). The target disk is named here because these values are the
  # host's own; nothing generic knows it.
  zfsInstall = {
    pool = "rpool";
    encrypted = false;
    keyDestination = "/var/lib/sops/age.key";
    poolKeyDestination = null;
    disks = [ targetDevice ];
    report = reportBin;
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
    encrypted = true;
    poolKeyDestination = poolKeyTarget;
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
      zfs set keylocation=file://${poolKeyInitrd} rpool
      ${reportBin} "E2E-POOL-ENCRYPTION $(zfs get -H -o value encryption rpool)"
      zfs create -o mountpoint=legacy rpool/root
      mkdir -p /mnt
      mount -t zfs rpool/root /mnt
      mkdir -p /mnt/boot
      mount "''${disk}-part1" /mnt/boot
    '';
    mount = pkgs.writeShellScript "mount-zfs-enc" ''
      set -euo pipefail
      zpool import rpool
      zfs load-key -L file:///tmp/zfs_root_key rpool
      mkdir -p /mnt
      mount -t zfs rpool/root /mnt
      mkdir -p /mnt/boot
      mount /dev/disk/by-id/virtio-target-part1 /mnt/boot
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

  mk = { name, modules, storage, secrets, slotName, install ? syntheticInstall,
         system ? "x86_64-linux", diskoInstall ? false }:
    let
      runtime = evalHost system ([
        ./modules/base.nix
        (import ./modules/e2e-result.nix { inherit record; })
        (import ./modules/marker.nix { inherit record; })
        { networking.hostName = name; }
      ] ++ modules);
      # A disko host's install prepare/mount ARE disko's own scripts — create+mount and
      # mount-existing — so the same layout that boots the host also formats it, and the
      # layout's own device list is what a create wipes. No hand-rolled partitioning.
      installFinal =
        if diskoInstall then {
          prepare = runtime.config.system.build.diskoScript;
          mount = runtime.config.system.build.mountScript;
          pool = "";
          encrypted = false;
          keyDestination = "/var/lib/sops/age.key";
          poolKeyDestination = null;
          disks = map (d: d.device) (lib.attrValues runtime.config.disko.devices.disk);
          report = reportBin;
        } else install;
      # The real extendModules step: each live variant is the host plus a face module,
      # evaluated by the composer's side of the world — never inside a block. There is one
      # variant per live format; no generic "live" fallback, so a missing one is an eval
      # error, not a silently wrong boot.
      liveNetboot = runtime.extendModules {
        modules = [ (import ./modules/live-netboot.nix { face = tools.netbootFace; }) ];
      };
    in
    {
      inherit name secrets system slotName;
      variants = {
        runtime = extract runtime // { inherit storage; };
        liveNetboot = extract liveNetboot;
        # The iso's runtime face needs the medium's LABEL, which only the composer knows —
        # so this variant is a function the composer applies.
        liveIso = label: extract (runtime.extendModules {
          modules = [ (import ./modules/live-iso.nix { inherit label; face = tools.isoFace; }) ];
        });
      };
      install = installFinal;
    };
in
{
  ext4 = mk {
    name = "e2e-ext4";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = withSecrets;
    slotName = "secrets";
  };

  memory = mk {
    name = "e2e-memory";
    modules = [ (import ./modules/read-only-store.nix {
      roStore = tools.roStore;
      device = "/dev/disk/by-partlabel/nixos";
    }) ];
    storage = "squashfs";
    secrets = noSecrets;
    slotName = "secrets";
  };

  zfs = mk {
    name = "e2e-zfs";
    modules = [ ./modules/disk-zfs.nix ];
    storage = "zfs";
    secrets = withSecrets;
    slotName = "secrets";
    install = zfsInstall;
  };

  zfs-enc = mk {
    name = "e2e-zfs-enc";
    # Its own machine identity: the reinstall e2e replaces the zfs host with this one and
    # a shared hostId would understate what a real replacement changes.
    modules = [ ./modules/disk-zfs.nix {
      networking.hostId = lib.mkForce "1badb002";
      boot.initrd.secrets.${poolKeyInitrd} = poolKeyTarget;
    } ];
    storage = "zfs";
    secrets = withSecrets // {
      files = withSecrets.files ++ [{
        target = "/pool.pass";
        source = "${fixture}/pool.pass";
        runtimeSource = "${fixture}/pool.pass";
      }];
    };
    slotName = "secrets";
    install = zfsEncInstall;
  };

  plain = mk {
    name = "e2e-plain";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = noSecrets;
    slotName = "secrets";
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
    slotName = "secrets";
  };

  # The ext4 INSTALL host: a real disko layout owns the disk AND the slot partition, so the
  # install action formats ext4 through disko's own scripts (no zpool anywhere). ONE
  # declaration names the slot: the layout's partition and the host record read the same
  # binding.
  ext4-install =
    let slotName = "secrets";
    in mk {
      name = "e2e-ext4-install";
      modules = [
        diskoModule
        (import ./modules/disk-ext4-layout.nix { device = targetDevice; inherit slotName; })
      ];
      storage = "ext4";
      secrets = withSecrets;
      diskoInstall = true;
      inherit slotName;
    };
}
