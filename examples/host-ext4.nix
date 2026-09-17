# The plain disk VM — the smallest full story. One disko layout owns the disk AND the
# slot partition, so the same declaration boots the host, formats it at install, and
# names where phase 2 writes. What you get out: bootable raw/qcow2 images, a live iso,
# secrets sidecars, and the personalize runner.
{ pkgs, tools, compose }:

let
  inherit (pkgs) lib;
  system = "x86_64-linux";
  slotName = "secrets";
  # The disk's STABLE identity — installs survive /dev/sdX shuffling, images don't care.
  device = "/dev/disk/by-id/virtio-main";

  # Stand-in for your real configuration: anything that evaluates as a nixosSystem works.
  base = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-ext4";
    users.allowNoPasswordLogin = true;
  };

  nixos = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [
      base
      ((import ../disko-pin.nix) + "/module.nix")
      # The reference layout: ESP + ext4 root + the vfat slot partition, named ONCE.
      (import ../tests/hosts/modules/disk-ext4-layout.nix { inherit device slotName; })
    ];
  };

  # Live variants are the same host wearing a face — extendModules, never a rebuild by
  # hand. The face modules are the reference implementations under tests/hosts/modules/.
  liveNetboot = nixos.extendModules {
    modules = [ (import ../tests/hosts/modules/live-netboot.nix { face = tools.netbootFace; }) ];
  };

  # Throwaway fixture bundle/keys so the example is self-contained. In production the
  # bundle and key paths come from your vault at RUNTIME — they are path strings on
  # purpose, secrets never enter the store.
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };

  extract = import ../tests/extract.nix;

  host = {
    name = "example-ext4";
    inherit system slotName;
    variants = {
      runtime = extract nixos // { storage = "ext4"; };
      liveNetboot = extract liveNetboot;
      liveIso = label: extract (nixos.extendModules {
        modules = [ (import ../tests/hosts/modules/live-iso.nix { inherit label; face = tools.isoFace; }) ];
      });
    };
    secrets = {
      delivery = [ "embedded" "sidecar" ];
      bundle = "${fixture}/bundle.yaml";
      keyTarget = "/sops.age";
      files = [{
        target = "/sops.age";
        source = "${fixture}/host.key";
        runtimeSource = "${fixture}/host.key";
      }];
    };
    # disko's own scripts are the install: create+mount and mount-existing (the
    # never-reformat path), and the layout's device list is what a create wipes.
    install = {
      prepare = nixos.config.system.build.diskoScript;
      mount = nixos.config.system.build.mountScript;
      pool = "";
      encrypted = false;
      keyDestination = "/var/lib/sops/age.key";
      poolKeyDestination = null;
      disks = map (d: d.device) (lib.attrValues nixos.config.disko.devices.disk);
      report = null;
    };
  };

  endpoints = compose host;
in
{
  inherit host endpoints;
  shown = {
    image-raw = endpoints.image-raw.file;             # dd to a disk, or boot as a VM
    image-qcow2 = endpoints.image-qcow2.file;         # the same disk for a cloud image
    image-iso = endpoints.image-iso.file;             # live: root in RAM, store on the medium
    image-secrets-vfat = endpoints.image-secrets-vfat.run;   # sidecar runners — phase 1
    image-personalize = endpoints.image-personalize.run;     # phase 2: fills the slot
    closure = endpoints.closure;
  };
}
