# The installing OS — the BLOCK's, not the caller's. A minimal, serial-consoled system
# whose one job is to run the repo's tested install action against the five values the
# caller handed over, then reboot into what it installed. The caller's values arrive as
# module arguments; nothing here reads a host configuration.
#
# Rooted on its own disk partition for now (the raw/qcow2 wrapper); the memory-rooted
# installer the iso/kexec wrappers need is the live-variant story applied to the installer,
# and is still open.
{ name, prepare, mount, toplevel, pool, keyDestination, niximilateInstall }:

{ pkgs, lib, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];
  system.stateVersion = "26.05";
  boot.loader.grub.enable = false;
  boot.kernelParams = [ "console=ttyS0" ];
  networking.useDHCP = false;
  networking.hostName = "${name}-installer";
  nix.enable = false;
  system.switch.enable = false;
  users.allowNoPasswordLogin = true;

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/nixos";
    fsType = "ext4";
  };

  # The target may be a zfs pool; the installer needs the module and a hostId of its own
  # (the installed system sets its own), but declares no pool — nothing auto-imports.
  boot.supportedFilesystems = [ "zfs" ];
  networking.hostId = "deadbeef";

  # The installer's OWN slot: personalize planted the install-time key there, and this is
  # where niximilate-install expects delivered keys. No slot, no key — the install still
  # runs; the target boots without an identity only if it never declared one.
  systemd.services.slot-key = {
    wantedBy = [ "multi-user.target" ];
    before = [ "niximilate-install.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.util-linux pkgs.coreutils ];
    script = ''
      slot=/dev/disk/by-partlabel/secrets
      if [ -e "$slot" ]; then
        mkdir -p /run/slot
        if mount -o ro "$slot" /run/slot 2>/dev/null; then
          if [ -s /run/slot/sops.age ]; then
            install -m 0600 /run/slot/sops.age /run/niximilate-sops.age
            echo "installer: install-time key taken from the slot" > /dev/console
          fi
          umount /run/slot
        fi
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
    path = [ niximilateInstall pkgs.systemd ];
    script = ''
      set -euo pipefail
      niximilate-install ${lib.escapeShellArgs [ prepare mount toplevel pool keyDestination ]}
      echo "NIXIMILATE-INSTALL-OK ${name}" > /dev/console
      systemctl reboot
    '';
  };
}
