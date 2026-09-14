# REAL hosts for the composer: each is an evaluated nixosSystem, and the composer's host
# record is produced by the one explicit extraction. The set spans the dimensions — disk vs
# memory, ext4 vs squashfs vs zfs, secrets delivered vs none — because that is what a
# hand-assembled record cannot prove.
{ pkgs }:

let
  fixture = import ../../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
  extract = import ../extract.nix;

  evalHost = modules:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      inherit modules;
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
    # outside that set is spelled absolutely.
    prepare = pkgs.writeShellScript "prepare-zfs" ''
      set -euo pipefail
      disk=/dev/vdb
      ${pkgs.gptfdisk}/bin/sgdisk -Z "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP "$disk"
      ${pkgs.gptfdisk}/bin/sgdisk -n 2:0:0 -t 2:bf01 -c 2:zfs "$disk"
      ${pkgs.systemd}/bin/udevadm settle
      ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n ESP "''${disk}1"
      zpool create -f -o ashift=12 -O mountpoint=none -O compression=on rpool "''${disk}2"
      zfs create -o mountpoint=legacy rpool/root
      mkdir -p /mnt
      mount -t zfs rpool/root /mnt
      mkdir -p /mnt/boot
      mount "''${disk}1" /mnt/boot
    '';
    mount = pkgs.writeShellScript "mount-zfs" ''
      set -euo pipefail
      zpool import rpool
      mkdir -p /mnt
      mount -t zfs rpool/root /mnt
      mkdir -p /mnt/boot
      mount /dev/vdb1 /mnt/boot
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

  mk = { name, modules, storage, secrets, install ? syntheticInstall }:
    let
      runtime = evalHost ([
        ./modules/base.nix
        ./modules/marker.nix
        { networking.hostName = name; }
      ] ++ modules);
      # The real extendModules step: the live variant is the host plus the live module,
      # evaluated by the composer's side of the world — never inside a block.
      live = runtime.extendModules { modules = [ ./modules/live.nix ]; };
    in
    {
      inherit name secrets;
      system = "x86_64-linux";
      variants = {
        runtime = extract runtime // { inherit storage; };
        live = extract live;
        # The iso's runtime face needs the medium's LABEL, which only the composer knows —
        # so this variant is a function the composer applies.
        liveIso = label: extract (runtime.extendModules {
          modules = [ (import ./modules/live-iso.nix { inherit label; }) ];
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

  plain = mk {
    name = "e2e-plain";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = noSecrets;
  };
}
