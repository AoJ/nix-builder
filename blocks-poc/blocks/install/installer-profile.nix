# The installing OS — the BLOCK's, not the caller's. A minimal, serial-consoled system
# whose one job is to run the repo's tested install action against the caller's values,
# then reboot into what it installed. The installer roots per wrapper: its own ext4
# partition (raw/qcow2), the netboot face (kexec/ipxe), or the iso face keyed by the
# medium's label (iso). Witnesses go to the result disk via e2e-record, not the console.
{ name, prepare, mount, toplevel, pool, keyDestination, rootMode, isoLabel
, slotName, slotFile, niximilateInstall, netbootFace, isoFace, e2eRecord }:

{ pkgs, lib, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ] ++ lib.optional (rootMode == "memory")
    (if isoLabel != null then isoFace { label = isoLabel; } else netbootFace);

  system.stateVersion = "26.05";
  boot.loader.grub.enable = false;
  boot.kernelParams = [ "console=ttyS0" ];
  boot.kernelModules = [ "vfat" ];
  networking.useDHCP = false;
  networking.hostName = "${name}-installer";
  nix.enable = false;
  users.allowNoPasswordLogin = true;

  fileSystems."/" = lib.mkIf (rootMode == "disk") {
    device = "/dev/disk/by-partlabel/nixos";
    fsType = "ext4";
  };

  # The target may be a zfs pool; the installer needs the module and a hostId of its own
  # (the installed system sets its own), but declares no pool — nothing auto-imports.
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "deadbeef";

  # The installer's OWN slot, whichever face delivered it: a partition beside its root
  # (disk wrapper), the iso's slot file, or the initrd-slot hand-over (memory wrapper).
  # This feeds the install action's delivered-key convention.
  systemd.services.slot-key = {
    wantedBy = [ "multi-user.target" ];
    before = [ "niximilate-install.service" ];
    serviceConfig.Type = "oneshot";
    path = [ e2eRecord pkgs.util-linux pkgs.coreutils ];
    script = ''
      deliver() {
        if [ -s "$1/sops.age" ]; then
          install -m 0600 "$1/sops.age" /run/niximilate-sops.age
          e2e-record "installer: install-time key taken from the slot"
        fi
        if [ -s "$1/pool.pass" ]; then
          install -m 0600 "$1/pool.pass" /tmp/zfs_root_key
          e2e-record "installer: pool passphrase taken from the slot"
        fi
      }
      slot=/dev/disk/by-partlabel/${slotName}
      iso_slot=/iso${slotFile}
      if [ -e "$slot" ]; then
        mkdir -p /run/slot
        if mount -o ro "$slot" /run/slot 2>/dev/null; then
          deliver /run/slot
          umount /run/slot
        fi
      elif [ -s "$iso_slot" ]; then
        mkdir -p /run/slot
        if mount -o ro,loop "$iso_slot" /run/slot 2>/dev/null; then
          deliver /run/slot
          umount /run/slot
        fi
      elif [ -d /run/initrd-slot ]; then
        deliver /run/initrd-slot
      fi
    '';
  };

  systemd.services.niximilate-install = {
    wantedBy = [ "multi-user.target" ];
    after = [ "slot-key.service" ];
    wants = [ "slot-key.service" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = [ niximilateInstall e2eRecord pkgs.systemd ];
    script = ''
      set -euo pipefail
      niximilate-install ${lib.escapeShellArgs [ prepare mount toplevel pool keyDestination ]}
      e2e-record "NIXIMILATE-INSTALL-OK ${name}"
      systemctl reboot
    '';
  };
}
