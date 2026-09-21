# The netboot RUNTIME face (squashfs-in-initrd): a tmpfs root, the read-only store overlaid
# out of the squashfs the initrd carries at the nixpkgs name /nix-store.squashfs (the shared
# roStore), and the initrd-slot HAND-OVER — initramfs contents are discarded at switch-root,
# so stage 1 copying the appended slot files to /run/initrd-slot IS the netboot slot's
# runtime face. Shared by the live-netboot variant and the memory-rooted installer.
{ pkgs, storeFileName, registrationPath }:
{ lib, config, ... }@args:

let
  media = lib.mkOverride 60;
  roStore = import ./ro-store.nix { inherit pkgs registrationPath; };
in
lib.mkMerge [
  (roStore args {
    # The squashfs is a plain file at the INITRAMFS root, not on a mounted filesystem, so
    # the mount unit's What is the bare absolute path — no /sysroot prefix (that is only for
    # a lower layer living under a real mount, like the iso's /iso).
    device = "/${storeFileName}";
    fsType = "squashfs";
    options = [ "loop" ];
    sysrootPrefixed = false;
  })
  {
    fileSystems."/" = media {
      device = "none";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };

    boot.initrd.systemd.services.initrd-slot = {
      description = "hand appended slot files over to the real root";
      wantedBy = [ "initrd.target" ];
      before = [ "initrd-switch-root.service" ];
      # AFTER /sysroot/run is mounted, not just /sysroot: the hand-over writes into the real
      # root's /run, and writing before that mount lands lets the mount shadow the files (and
      # races the copy into a failure). RequiresMountsFor makes the ordering explicit.
      after = [ "sysroot.mount" "sysroot-run.mount" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = [ "/sysroot/run" ];
      };
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu
        mkdir -p /sysroot/run/initrd-slot
        for f in /*; do
          if [ -f "$f" ] && [ "$f" != /${storeFileName} ]; then
            case "$f" in
              /.slot-*) : ;;
              /init) : ;;
              *) cp "$f" /sysroot/run/initrd-slot/ ;;
            esac
          fi
        done
      '';
    };
  }
]
