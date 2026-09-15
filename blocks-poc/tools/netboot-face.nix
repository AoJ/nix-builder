# The netboot RUNTIME face (DECIDED: squashfs-in-initrd — compressed, lazily read): the
# store rides the initrd as /nix-store.squashfs (the nixpkgs name; the netboot part writes
# it, both sides take it from that convention), stage 1 loop-mounts it read-only under an
# overlay, and the root is a tmpfs. Entries use nixpkgs' image-media priority (60), so they
# override a host's own disk declarations without mkForce — L1/L4's "the live variant does
# not use the host's storage declaration" is this priority.
#
# Files personalize appended to the initrd surface at /run/initrd-slot in the booted
# system: initramfs contents are discarded at switch-root, so stage 1 hands them over —
# that hand-over IS the netboot slot's runtime face.
{ lib, pkgs, config, ... }:

let
  media = lib.mkOverride 60;
  # Under systemd stage 1 the squashfs lives at the INITRAMFS root, and a mount unit's What
  # must be a NORMALIZED absolute path — a ".." in it fails unit load with EPERM (measured).
  # After switch-root the entry points at nothing, which is fine: the mount is already
  # active and travels — the same bargain the iso face strikes.
  squashWhere =
    if config.boot.initrd.systemd.enable
    then "/nix-store.squashfs"
    else "../nix-store.squashfs";
in
{
  fileSystems."/" = media {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=0755" ];
  };
  fileSystems."/nix/.ro-store" = media {
    device = squashWhere;
    fsType = "squashfs";
    options = [ "loop" ];
    neededForBoot = true;
  };
  fileSystems."/nix/.rw-store" = media {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };
  # The typed overlay, not hand-written options: it is what prefixes the layer paths for
  # the initrd namespace and creates upper/work.
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

  boot.initrd.systemd.services.initrd-slot = {
    description = "hand appended slot files over to the real root";
    wantedBy = [ "initrd.target" ];
    before = [ "initrd-switch-root.service" ];
    after = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /sysroot/run/initrd-slot
      for f in /*; do
        if [ -f "$f" ] && [ "$f" != /nix-store.squashfs ]; then
          case "$f" in
            /.slot-*) : ;;
            /init) : ;;
            *) cp "$f" /sysroot/run/initrd-slot/ ;;
          esac
        fi
      done
    '';
  };

  boot.postBootCommands = ''
    if [ -e /nix/store/nix-path-registration ] && [ ! -e /nix/var/nix/db/db.sqlite ]; then
      ${pkgs.nix}/bin/nix-store --load-db < /nix/store/nix-path-registration
    fi
  '';
}
