# The installing OS — the BLOCK's, not the caller's. A minimal, serial-consoled system
# whose one job is to run the install action against the caller's values, then leave the
# machine on what it delivered. The installer roots per wrapper: its own ext4 partition
# (raw/qcow2), the netboot face (kexec/ipxe), or the iso face keyed by the medium's label
# (iso). Its hardware support is the HOST's declaration (the machine record) — it boots
# exactly where the host boots, and carries nothing the host did not claim to need.
{ name, kind, payload, pool, storage, encrypted, slotName, slotFiles
, rootMode, isoLabel, slotFace, disks, report, machine, actionInstall, completion, handover
, netbootFace, isoFace }:

{ pkgs, lib, modulesPath, ... }:
let
  reportFn =
    if report == null
    then "report_line() { :; }"
    else ''report_line() { ${lib.escapeShellArg report} "$@"; }'';
  # What the host said its slot carries, by path — the act checks arrival, never content.
  expectedSlotFiles = pkgs.writeText "${name}-slot-files"
    (lib.concatMapStrings (f: "${f}\n") slotFiles);

  # The action takes the same nine arguments either way; an image delivery has no create,
  # mount or toplevel to name, and says so with empty ones.
  actionArgs =
    if kind == "image"
    then [ "" "" slotName expectedSlotFiles storage pool "" ]
    else [ payload.prepare payload.toplevel slotName expectedSlotFiles
           storage pool (if encrypted then "true" else "false") ];

  payloadEnv = lib.optionalString (kind == "image")
    "payload_image=${lib.escapeShellArg payload.image} ";

  # Handing over to what was just installed: its kernel rides in the INSTALLER's store,
  # so nothing has to be read back off the target. `-f` is the whole point of the ending —
  # it leaves no chance for firmware to find the install medium a second time.
  handoverScript = lib.optionalString (completion == "kexec") ''
    kexec --load ${handover}/kernel --initrd=${handover}/initrd \
      --command-line="init=${handover}/init $(cat ${handover}/kernel-params)"
    report_line "HANDOVER ${name}"
    kexec -e
  '';

  finish = {
    kexec = handoverScript;
    reboot = "systemctl reboot";
    poweroff = "systemctl poweroff";
  }.${completion};
in
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
  ] ++ lib.optional (rootMode == "memory")
    (if isoLabel != null then isoFace { label = isoLabel; } else netbootFace);

  system.stateVersion = "26.05";
  boot.loader.grub.enable = false;
  boot.kernelParams = [ "console=ttyS0" ];
  boot.kernelPackages = machine.kernelPackages;
  boot.initrd.availableKernelModules = machine.initrdAvailableKernelModules;
  boot.initrd.kernelModules = machine.initrdKernelModules;
  boot.kernelModules = machine.kernelModules ++ [ "vfat" ];
  hardware.firmware = machine.firmware;
  networking.useDHCP = false;
  networking.hostName = "${name}-installer";
  nix.enable = false;
  users.allowNoPasswordLogin = true;

  # If the install wedges, the machine resets rather than hanging forever on a console-less
  # box — and the timer stays armed ACROSS the final reboot, so the installed system must
  # take the watchdog over within the window or the box resets instead of hanging in a bad
  # boot. The driver arrives with machine.kernelModules (the host's own watchdog
  # declaration); without a device systemd logs and carries on.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "90s";
    RebootWatchdogSec = "300s";
  };

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
  # Its contents are laid out at ONE published path and nothing here looks at what they
  # are: the host's own storage scripts read what they need from there, and the act
  # carries the same files to the target's slot.
  systemd.services.slot = {
    wantedBy = [ "multi-user.target" ];
    before = [ "action-install.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.util-linux pkgs.coreutils ];
    script = ''
      ${reportFn}
      deliver() {
        cp -a "$1"/. /run/slot/
        report_line "installer: slot taken over ($(find /run/slot -type f | wc -l) files)"
      }
      mkdir -p /run/slot /run/slot-src
      chmod 0700 /run/slot
      ${
        if slotFace ? partlabel then ''
          dev=/dev/disk/by-partlabel/${slotFace.partlabel}
          if mount -o ro "$dev" /run/slot-src 2>/dev/null; then
            deliver /run/slot-src
            umount /run/slot-src
          fi
        '' else if slotFace ? path then ''
          file=${slotFace.mount}${slotFace.path}
          if mount -o ro,loop "$file" /run/slot-src 2>/dev/null; then
            deliver /run/slot-src
            umount /run/slot-src
          fi
        '' else ''
          [ -d ${slotFace.dir} ] && deliver ${slotFace.dir}
        ''
      }
    '';
  };

  systemd.services.action-install = {
    wantedBy = [ "multi-user.target" ];
    after = [ "slot.service" ];
    wants = [ "slot.service" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = [ actionInstall pkgs.systemd ] ++ lib.optional (completion == "kexec") pkgs.kexec-tools;
    # A refused or failed install must terminate the machine, visibly: a report line and a
    # poweroff, so a headless box does not sit wedged and a reboot cannot masquerade as
    # success. Booting this artifact IS the intent — nothing asks a second time, because an
    # install replaces what is on the declared disks by definition, and anything else would
    # leave a machine that is half of two systems.
    script = ''
      set -euo pipefail
      ${reportFn}
      fail() {
        report_line "INSTALL-FAILED ${name}"
        systemctl poweroff
        exit 1
      }
      ${payloadEnv}action-install ${
        lib.escapeShellArgs (actionArgs ++ disks)} || fail
      report_line "INSTALL-OK ${name}"
      ${finish}
    '';
  };
}
