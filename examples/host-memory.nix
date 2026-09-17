# The appliance — memory-rooted, squashfs store. The runtime image IS the deliverable:
# a squashfs store is written by the image, never by an install (law L6), so every
# -install endpoint of this host is a named hole that refuses at eval. Deploying means
# shipping `image-raw` itself (or netbooting `image-kexec`); the disk carries a read-only
# store and the root lives in RAM.
{ pkgs, tools, compose }:

let
  system = "x86_64-linux";
  slotName = "secrets";

  base = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-memory";
    users.allowNoPasswordLogin = true;
  };

  nixos = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [
      base
      # The read-only-store mechanism (tmpfs root, squashfs store mounted from the named
      # partition, nix database loaded at boot) — the reference module the memory face
      # rests on.
      (import ../tests/hosts/modules/read-only-store.nix {
        roStore = tools.roStore;
        device = "/dev/disk/by-partlabel/nixos";
      })
    ];
  };
  liveNetboot = nixos.extendModules {
    modules = [ (import ../tests/hosts/modules/live-netboot.nix { face = tools.netbootFace; }) ];
  };

  extract = import ../tests/extract.nix;

  host = {
    name = "example-memory";
    inherit system slotName;
    variants = {
      runtime = extract nixos // { storage = "squashfs"; };
      liveNetboot = extract liveNetboot;
      liveIso = label: extract (nixos.extendModules {
        modules = [ (import ../tests/hosts/modules/live-iso.nix { inherit label; face = tools.isoFace; }) ];
      });
    };
    # No secrets declared: every secrets/personalize endpoint exists and is a silent
    # no-op — nothing may key off "the host has a bundle".
    secrets = {
      delivery = [ ];
      files = [ ];
    };
    # Unused by any reachable endpoint (the -install set is L6 holes), present so the
    # record has one shape for every host.
    install = {
      prepare = pkgs.writeShellScript "prepare" "exit 1";
      mount = pkgs.writeShellScript "mount" "exit 1";
      pool = "";
      encrypted = false;
      keyDestination = "/var/lib/sops/age.key";
      poolKeyDestination = null;
      disks = [ "/dev/disk/by-id/virtio-main" ];
      report = null;
    };
  };

  endpoints = compose host;
in
{
  inherit host endpoints;
  shown = {
    image-raw = endpoints.image-raw.file;     # the deliverable: ESP + read-only store
    image-kexec = endpoints.image-kexec.file; # the same appliance, netbooted
    closure = endpoints.closure;
  };
}
