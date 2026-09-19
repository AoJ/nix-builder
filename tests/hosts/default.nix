# REAL hosts for the composer: each is an evaluated nixosSystem, and the composer's host
# record is produced by the one explicit extraction. The set spans the dimensions — disk vs
# memory, ext4 vs squashfs vs zfs, secrets delivered vs none — because that is what a
# hand-assembled record cannot prove.
{ pkgs, tools, record }:

let
  fixture = import ../../blocks/personalize/fixture.nix { inherit pkgs; };
  extract = import ../../lib/extract.nix;
  inherit (pkgs) lib;
  diskoModule = (import ../../disko-pin.nix) + "/module.nix";
  targetDevice = "/dev/disk/by-id/virtio-target";
  reportBin = "${record}/bin/e2e-record";
  slotName = "secrets";
  # Where the install action lays its slot out while it runs — published by the builder,
  # read by these hosts' own storage scripts. Blocks never learns which file is which.
  installSlot = (import ../../lib/api.nix).paths.installSlot;
  # The encrypted host's own unlock story, which is layout land: the slot partition it
  # gets on the target is mounted here, and its initrd carries a copy of the passphrase
  # from there — so stage 1 reads a file that exists exactly when it runs.
  slotMount = "/var/lib/slot";
  poolKeyInitrd = "/pool.key";

  evalHost = system: modules:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit system modules;
    };

  syntheticInstall = {
    script = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
    pool = "rpool";
    encrypted = false;
    disks = [ "/dev/target" ];
    report = null;
  };

  # The zfs layout, written out by hand because a pool is not a disko layout: an ESP, the
  # SLOT partition the installed host reads its secrets from, and the pool. The slot is
  # part of the layout exactly like the ESP is — the install fills it, the host mounts it.
  zfsPartitions = ''
    disk=${targetDevice}
    ${pkgs.gptfdisk}/bin/sgdisk -Z "$disk"
    ${pkgs.gptfdisk}/bin/sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP "$disk"
    ${pkgs.gptfdisk}/bin/sgdisk -n 2:0:+8M -t 2:8300 -c 2:${slotName} "$disk"
    ${pkgs.gptfdisk}/bin/sgdisk -n 3:0:0 -t 3:bf01 -c 3:zfs "$disk"
    ${pkgs.systemd}/bin/udevadm settle
    ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n ESP "''${disk}-part1"
    ${pkgs.dosfstools}/bin/mkfs.fat -n SLOT "''${disk}-part2"
  '';
  zfsMountTail = ''
    mkdir -p /mnt
    mount -t zfs rpool/root /mnt
    mkdir -p /mnt/boot
    mount ${targetDevice}-part1 /mnt/boot
  '';

  # The zfs host's REAL extracted install values: its install script creates the pool and
  # mounts it at /mnt — the diskoScript role, written by hand because a pool is not a disko
  # layout. The target disk is named here because these values are the host's own; nothing
  # generic knows it.
  zfsInstall = {
    pool = "rpool";
    encrypted = false;
    disks = [ targetDevice ];
    report = reportBin;
    # Runs under the install action's PATH (nix, zfs, util-linux, coreutils); anything
    # outside that set is spelled absolutely. The target is named by the STABLE identity
    # the e2e attaches it with (a virtio serial), so the same extracted values work under
    # every wrapper — a disk-rooted installer shifts /dev/vdX, an identity does not.
    script = pkgs.writeShellScript "prepare-zfs" ''
      set -euo pipefail
      ${zfsPartitions}
      zpool create -f -o ashift=12 -O mountpoint=none -O compression=on rpool "''${disk}-part3"
      zfs create -o mountpoint=legacy rpool/root
      ${zfsMountTail}
    '';
  };

  # L3 in practice: the pool is created encrypted with the passphrase that rode the slot —
  # one more file in the same embedded delivery (DECIDED: the bricks combine). Which file
  # that is, is this host's own knowledge: it reads it off the published install-slot path,
  # and blocks never learns what `pool.pass` means. The witness line is read back by the
  # encrypted-install e2e.
  zfsEncInstall = zfsInstall // {
    encrypted = true;
    script = pkgs.writeShellScript "prepare-zfs-enc" ''
      set -euo pipefail
      ${zfsPartitions}
      zpool create -f -o ashift=12 -O mountpoint=none -O compression=on \
        -O encryption=on -O keyformat=passphrase \
        -O keylocation=file://${installSlot}/pool.pass rpool "''${disk}-part3"
      zfs set keylocation=file://${poolKeyInitrd} rpool
      ${reportBin} "E2E-POOL-ENCRYPTION $(zfs get -H -o value encryption rpool)"
      zfs create -o mountpoint=legacy rpool/root
      ${zfsMountTail}
      # This host reads its passphrase out of the slot at BOOT (an initrd secret), and
      # the bootloader step that bakes it in runs during the install — so the slot has to
      # be mounted where this host says it lives before nixos-install runs.
      mkdir -p /mnt${slotMount}
      mount ${targetDevice}-part2 /mnt${slotMount}
    '';
  };

  noSecrets = {
    delivery = [ ];
    files = [ ];
  };

  # The host's own secrets, as the host sees them: a file name it chose, and bytes it
  # brought. The fixture key is a plain file here because a test has one — a deploy with
  # the material in a variable would say `content.env` instead.
  withSecrets = {
    delivery = [ "embedded" "sidecar" ];
    files = [{
      target = "/sops.age";
      content.file = "${fixture}/host.key";
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
      # A disko host's install script IS disko's own create script, so the same layout that
      # boots the host also formats it, and the layout's own device list is what the wipe
      # clears. No hand-rolled partitioning.
      installFinal =
        if diskoInstall then {
          script = runtime.config.system.build.diskoScript;
          pool = "";
          encrypted = false;
          disks = map (d: d.device) (lib.attrValues runtime.config.disko.devices.disk);
          report = reportBin;
        } else install;
      # The real extendModules step: each live variant is the host plus a face module,
      # evaluated by the composer's side of the world — never inside a block. There is one
      # variant per live format; no generic "live" fallback, so a missing one is an eval
      # error, not a silently wrong boot.
      liveNetboot = runtime.extendModules {
        modules = [ (import ../../modules/live-netboot.nix { face = tools.netbootFace; }) ];
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
          modules = [ (import ../../modules/live-iso.nix { inherit label; face = tools.isoFace; }) ];
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
    inherit slotName;
  };

  memory = mk {
    name = "e2e-memory";
    modules = [ (import ../../modules/read-only-store.nix {
      roStore = tools.roStore;
      device = "/dev/disk/by-partlabel/nixos";
    }) ];
    storage = "squashfs";
    secrets = noSecrets;
    inherit slotName;
  };

  zfs = mk {
    name = "e2e-zfs";
    modules = [ ./modules/disk-zfs.nix ];
    storage = "zfs";
    secrets = withSecrets;
    inherit slotName;
    install = zfsInstall;
  };

  zfs-enc = mk {
    name = "e2e-zfs-enc";
    # Its own machine identity: the reinstall e2e replaces the zfs host with this one and
    # a shared hostId would understate what a real replacement changes.
    modules = [ ./modules/disk-zfs.nix {
      networking.hostId = lib.mkForce "1badb002";
      # THE HOST's unlock story, none of which blocks knows: its slot partition mounts
      # here, and the initrd carries the passphrase from it — the file this host put in
      # its own slot, under a name of its own choosing.
      fileSystems.${slotMount} = {
        device = "/dev/disk/by-partlabel/${slotName}";
        fsType = "vfat";
        options = [ "ro" "umask=0077" ];
      };
      boot.initrd.secrets.${poolKeyInitrd} = "${slotMount}/pool.pass";
    } ];
    storage = "zfs";
    secrets = withSecrets // {
      files = withSecrets.files ++ [{
        target = "/pool.pass";
        content.file = "${fixture}/pool.pass";
      }];
    };
    inherit slotName;
    install = zfsEncInstall;
  };

  plain = mk {
    name = "e2e-plain";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = noSecrets;
    inherit slotName;
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
    inherit slotName;
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


  # The IMAGE delivery: the same ext4 host, but declaring no install script at all — so
  # what reaches the target is its own disk image, written as it is. Its disk layout is the
  # image's own (ESP, store, slot), which is why nothing here describes one.
  image-install = mk {
    name = "e2e-image-install";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = withSecrets;
    inherit slotName;
    install = {
      disks = [ targetDevice ];
      report = reportBin;
      # Hand straight to what was written: a boot medium left in the machine would
      # otherwise be found again by firmware, and the install would start over.
      completion = "kexec";
    };
  };
}
