# The installing OS — the BLOCK's, not the caller's. A minimal, serial-consoled system
# whose one job is to run the install action against the caller's values, then reboot into
# what it installed. The installer roots per wrapper: its own ext4 partition (raw/qcow2),
# the netboot face (kexec/ipxe), or the iso face keyed by the medium's label (iso).
{ name, prepare, mount, toplevel, pool, storage, keyDestination, rootMode, isoLabel
, slotFace, disks, report, actionInstall, netbootFace, isoFace }:

{ pkgs, lib, modulesPath, ... }:
let
  reportFn =
    if report == null
    then "report_line() { :; }"
    else ''report_line() { ${lib.escapeShellArg report} "$@"; }'';
in
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    # The broad driver set (virtio included), so the installer boots real hardware and not
    # only qemu.
    (modulesPath + "/profiles/all-hardware.nix")
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

  # If the install wedges, the machine resets rather than hanging forever on a console-less
  # box. Harmless under qemu without a watchdog device; real hardware arms the timer.
  systemd.watchdog.runtimeTime = "90s";

  fileSystems."/" = lib.mkIf (rootMode == "disk") {
    device = "/dev/disk/by-partlabel/nixos";
    fsType = "ext4";
  };

  # Only a zfs target puts zfs into the installer: the kernel module here, the userland via
  # the action's own inputs. The installer needs a hostId of its own (the installed system
  # sets its own) but declares no pool — nothing auto-imports.
  boot.supportedFilesystems = lib.mkIf (storage == "zfs") [ "zfs" ];
  boot.zfs.forceImportRoot = lib.mkIf (storage == "zfs") false;
  networking.hostId = lib.mkIf (storage == "zfs") "deadbeef";

  # The installer's OWN slot, whichever face delivered it: a partition beside its root
  # (disk wrapper), the iso's slot file, or the initrd-slot hand-over (memory wrapper).
  # This feeds the install action's delivered-key convention.
  systemd.services.slot-key = {
    wantedBy = [ "multi-user.target" ];
    before = [ "action-install.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.util-linux pkgs.coreutils ];
    script = ''
      ${reportFn}
      deliver() {
        if [ -s "$1/sops.age" ]; then
          install -m 0600 "$1/sops.age" /run/sops.age
          report_line "installer: install-time key taken from the slot"
        fi
        if [ -s "$1/pool.pass" ]; then
          install -m 0600 "$1/pool.pass" /tmp/zfs_root_key
          report_line "installer: pool passphrase taken from the slot"
        fi
      }
      ${
        if slotFace ? partlabel then ''
          dev=/dev/disk/by-partlabel/${slotFace.partlabel}
          mkdir -p /run/slot
          if mount -o ro "$dev" /run/slot 2>/dev/null; then
            deliver /run/slot
            umount /run/slot
          fi
        '' else if slotFace ? path then ''
          file=${slotFace.mount}${slotFace.path}
          mkdir -p /run/slot
          if mount -o ro,loop "$file" /run/slot 2>/dev/null; then
            deliver /run/slot
            umount /run/slot
          fi
        '' else ''
          [ -d ${slotFace.dir} ] && deliver ${slotFace.dir}
        ''
      }
    '';
  };

  systemd.services.action-install = {
    wantedBy = [ "multi-user.target" ];
    after = [ "slot-key.service" ];
    wants = [ "slot-key.service" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = [ actionInstall pkgs.systemd ];
    script = ''
      set -euo pipefail
      ${reportFn}
      action-install ${lib.escapeShellArgs
        ([ prepare mount toplevel keyDestination storage pool ] ++ disks)}
      report_line "INSTALL-OK ${name}"
      systemctl reboot
    '';
  };
}
