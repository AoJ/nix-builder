# What the front door derives from a configuration, and what it refuses to guess. Each
# case is a real evaluated system, because the whole claim is "it reads what the host
# already states" — a hand-built fixture could not prove that.
{ pkgs, tools }:

let
  inherit (pkgs) lib;
  api = import ./api.nix;
  inherit (api.mk { inherit pkgs; }) recordFor imagesFor;

  diskoModule = (import ../disko-pin.nix) + "/module.nix";
  device = "/dev/disk/by-id/example-main";

  evalHost = modules: import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ({ modulesPath, ... }: {
        imports = [ (modulesPath + "/profiles/minimal.nix") ];
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        users.allowNoPasswordLogin = true;
      })
    ] ++ modules;
  };

  # A disko host: the layout states the disk, and the front door must take prepare, mount
  # and the disk list from it rather than asking again.
  diskoHost = evalHost [
    diskoModule
    {
      networking.hostName = "derived-ext4";
      disko.devices.disk.main = {
        type = "disk";
        inherit device;
        content.type = "gpt";
        content.partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; };
          };
          nixos = {
            size = "100%";
            content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };
          };
          secrets = {
            size = "8M";
            label = "secrets";
            content = { type = "filesystem"; format = "vfat"; };
          };
        };
      };
    }
  ];

  zfsHost = evalHost [{
    networking.hostName = "derived-zfs";
    networking.hostId = "8425e349";
    boot.supportedFilesystems = [ "zfs" ];
    fileSystems."/" = { device = "tank/system/root"; fsType = "zfs"; };
    fileSystems."/boot" = { device = "/dev/disk/by-partlabel/ESP"; fsType = "vfat"; };
  }];

  memoryHost = evalHost [{
    networking.hostName = "derived-memory";
    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
  }];

  unknownHost = evalHost [{
    networking.hostName = "derived-xfs";
    fileSystems."/" = { device = "/dev/sda1"; fsType = "xfs"; };
  }];

  record = host: extra: recordFor ({ inherit host; slotName = "secrets"; } // extra);
  forced = v: builtins.unsafeDiscardStringContext v.drvPath;
  refused = v: !(builtins.tryEval (builtins.seq v null)).success;
  # A derivation only refuses once something forces what is inside it.
  refusedBuild = v: !(builtins.tryEval (forced v)).success;

  diskoRecord = record diskoHost { };
  zfsRecord = record zfsHost {
    install = {
      prepare = pkgs.writeShellScript "prepare" "true";
      disks = [ device ];
    };
  };
in

assert lib.assertMsg (diskoRecord.name == "derived-ext4")
  "the artifact name comes from the host's own networking.hostName";
assert lib.assertMsg (diskoRecord.variants.runtime.storage == "ext4")
  "ext4 storage is read from the root filesystem, not asked for";
assert lib.assertMsg (diskoRecord.install.disks == [ device ])
  "the wipe's blast radius is the disko layout's own device list";
assert lib.assertMsg
  (diskoRecord.install.prepare == diskoHost.config.system.build.diskoScript)
  "a disko host does not write an install script: disko generates it";
assert lib.assertMsg (diskoRecord.install.pool == "")
  "a plain filesystem has no pool";
assert lib.assertMsg (diskoRecord.variants.runtime.rootMode == "disk")
  "the root mode is derived by the extraction";

assert lib.assertMsg (zfsRecord.variants.runtime.storage == "zfs")
  "zfs storage is read from the root filesystem";
assert lib.assertMsg (zfsRecord.install.pool == "tank")
  "the pool is the first component of the root dataset, not a second declaration";

assert lib.assertMsg
  ((record memoryHost { }).variants.runtime.storage == "squashfs")
  "a tmpfs root is what memory-rooted means, and its store is a squashfs";
assert lib.assertMsg
  ((record memoryHost { }).variants.runtime.rootMode == "memory")
  "the same fact drives the root mode";

assert lib.assertMsg (refused (record unknownHost { }).variants.runtime.storage)
  "an unrecognised root filesystem is refused, never guessed at";

# A host with no install recipe keeps every other endpoint: the installers refuse when
# ASKED FOR, and nothing else notices.
assert lib.assertMsg
  (refusedBuild (imagesFor { host = zfsHost; slotName = "secrets"; }).image-kexec-install.file)
  "an installer without a recipe refuses by name";
assert lib.assertMsg
  (forced (imagesFor { host = memoryHost; slotName = "secrets"; }).image-raw.file != null)
  "a host with no install recipe still builds its runtime images";

pkgs.writeText "test-images-for" "the front door derives what it can and refuses the rest"
