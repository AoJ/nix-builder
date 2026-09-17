# The host record — extracted DATA, never a configuration: derivations and strings the
# composer reads, produced by the one explicit extraction from your evaluated
# nixosSystem. Adapt the module list to your machine; the record's shape stays.
{ pkgs, tools, builder }:

let
  inherit (pkgs) lib;
  system = "x86_64-linux";
  slotName = "secrets";
  device = "/dev/disk/by-id/nvme-eui.0123456789abcdef";

  configuration = { modulesPath, ... }: {
    # Your real configuration. The installer inherits the hardware support declared
    # here (kernel, module sets, firmware) — it boots exactly where the host boots.
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    networking.hostName = "consumer-demo";
    users.allowNoPasswordLogin = true;
  };

  nixos = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [
      configuration
      (builder.inputs.disko + "/module.nix")
      # The reference disko layout: ESP + ext4 root + the vfat slot partition. Bring
      # your own layout; the slot stays the partition NAMED ${slotName}.
      (import (builder + "/tests/hosts/modules/disk-ext4-layout.nix") {
        inherit device slotName;
      })
    ];
  };

  # The reference extraction and face modules ride the builder input.
  extract = builder.lib.extract;
  liveNetboot = nixos.extendModules {
    modules = [
      (import (builder + "/tests/hosts/modules/live-netboot.nix") {
        face = tools.netbootFace;
      })
    ];
  };
in
{
  name = "consumer-demo";
  inherit system slotName;
  variants = {
    runtime = extract nixos // { storage = "ext4"; };
    liveNetboot = extract liveNetboot;
    liveIso = label: extract (nixos.extendModules {
      modules = [
        (import (builder + "/tests/hosts/modules/live-iso.nix") {
          inherit label;
          face = tools.isoFace;
        })
      ];
    });
  };
  secrets = {
    delivery = [ "embedded" "sidecar" ];
    # Runtime PATH STRINGS from your vault — secrets never enter the store. The bundle
    # is sops, encrypted to the host's age key; keyTarget names the key file's place
    # in the slot.
    bundle = "/run/secrets/consumer-demo/bundle.yaml";
    keyTarget = "/sops.age";
    files = [{
      target = "/sops.age";
      source = "/run/secrets/consumer-demo/host.key";
      runtimeSource = "/run/secrets/consumer-demo/host.key";
    }];
  };
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
}
