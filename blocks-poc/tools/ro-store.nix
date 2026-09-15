# The read-only store mechanism, in ONE place: a lower squashfs, a tmpfs upper, and the
# overlay that makes /nix/store writable — plus the register-nix-paths service that loads
# the DB dump the image carries. Every face that boots off a read-only store (netboot, iso,
# the appliance's own partition) is this, differing only in WHERE the lower layer is.
#
# The overlay is not optional: nix-store --load-db creates /nix/store/.links, so a bare
# read-only mount at /nix/store fails ("Read-only file system") and the DB stays empty. A
# writable upper is what nixpkgs' own live media always use.
{ pkgs }:

# lower : { device; fsType; options ? []; sysrootPrefixed ? false; priority ? 60; }
#
# priority: null for a host's OWN runtime store (a plain declaration), 60 (nixpkgs'
# image-media priority) for a LIVE face layered over a host that already has one — so the
# face's medium wins over the runtime partition instead of colliding with it.
{ lib, config, ... }@args:
lower:

let
  media = if (lower.priority or 60) == null then (x: x) else lib.mkOverride (lower.priority or 60);
  sysroot = lib.optionalString config.boot.initrd.systemd.enable "/sysroot";
  dev = if lower.sysrootPrefixed or false then "${sysroot}${lower.device}" else lower.device;
in
{
  fileSystems."/nix/.ro-store" = media {
    device = dev;
    fsType = lower.fsType;
    options = lower.options or [ ];
    neededForBoot = true;
  };
  fileSystems."/nix/.rw-store" = media {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };
  fileSystems."/nix/store" = media {
    overlay = {
      lowerdir = [ "/nix/.ro-store" ];
      upperdir = "/nix/.rw-store/store";
      workdir = "/nix/.rw-store/work";
    };
    neededForBoot = true;
  };
  boot.initrd.availableKernelModules = [ "squashfs" "overlay" ];
  boot.initrd.kernelModules = [ "loop" "overlay" ];

  # A SERVICE, not boot.postBootCommands, which the systemd stage-2 init never runs. load-db
  # merges, so no db.sqlite guard — a read-only lower can carry an empty db.sqlite that would
  # otherwise skip the load. mkdir first: nix.enable = false drops the tmpfiles that would
  # create /nix/var/nix.
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
      mkdir -p /nix/var/nix/db
      if [ -e /nix/store/nix-path-registration ]; then
        ${pkgs.nix}/bin/nix-store --load-db < /nix/store/nix-path-registration
      fi
    '';
  };
}
