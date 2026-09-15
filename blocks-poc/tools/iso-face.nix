# The iso RUNTIME face: the medium found by the LABEL both sides derive from one artifact
# name through the ids tool, the squashfs store loop-mounted read-only out of it, a tmpfs
# root. Entries use nixpkgs' image-media priority (60), so the face overrides a host's disk
# declarations without a fight — L1 as a priority. Shared by the live variant and the
# iso-rooted installer.
{ label }:
{ lib, pkgs, config, ... }:

let
  media = lib.mkOverride 60;
  sysroot = lib.optionalString config.boot.initrd.systemd.enable "/sysroot";
in
{
  fileSystems."/" = media {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=0755" ];
  };
  fileSystems."/iso" = media {
    device = "/dev/disk/by-label/${label}";
    fsType = "iso9660";
    options = [ "ro" ];
    neededForBoot = true;
  };
  fileSystems."/nix/store" = media {
    device = "${sysroot}/iso/nix-store.squashfs";
    fsType = "squashfs";
    options = [ "loop" "ro" ];
    neededForBoot = true;
  };
  boot.initrd.kernelModules = [ "loop" ];
  boot.initrd.availableKernelModules = [ "iso9660" "squashfs" ];
  # The read-only store carries paths but not the nix DB (it lives at /nix/var/nix/db, a
  # tmpfs that boots empty). Load the dump nixpkgs ships in the image as a SERVICE — the
  # systemd stage-2 init never runs boot.postBootCommands. The nixpkgs register pattern.
  systemd.services.register-nix-paths = {
    description = "Register Nix Store Paths";
    unitConfig.DefaultDependencies = false;
    wantedBy = [ "sysinit.target" ];
    before = [ "sysinit.target" "shutdown.target" ];
    after = [ "local-fs.target" ];
    conflicts = [ "shutdown.target" ];
    restartIfChanged = false;
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      if [ -e /nix/store/nix-path-registration ] && [ ! -e /nix/var/nix/db/db.sqlite ]; then
        ${pkgs.nix}/bin/nix-store --load-db < /nix/store/nix-path-registration
      fi
    '';
  };
}
