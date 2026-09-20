# The front door: one evaluated NixOS system in, the whole endpoint set out.
#
# The host record underneath stays what it is — the contract between the one thing that
# knows a host and the blocks, which never see one. This layer is what fills it in: it
# READS what the configuration already states (its storage, its machine, its layout) and
# asks only for what a configuration cannot know — the slot's name, where secrets will be
# at phase-2 time, and a storage recipe for hosts whose layout is not disko.
#
# Everything derived here is derived from ONE place in the configuration and refuses by
# name when it cannot be: a guess is how a host ends up built for a disk it does not have.
{ lib, compose, modules, extract }:

let
  recordFor =
    { host
    , slotName
    , secrets ? { }
    , install ? { }
    , name ? host.config.networking.hostName
    }:
    let
      cfg = host.config;

      refuse = why: throw "imagesFor(${toString name}): ${why}";

      rootFs = cfg.fileSystems."/" or (refuse "the host declares no root filesystem");

      storage =
        if rootFs.fsType == "zfs" then "zfs"
        else if rootFs.fsType == "ext4" then "ext4"
        else if rootFs.fsType == "tmpfs" then "squashfs"
        else refuse ("cannot tell the storage from fileSystems.\"/\".fsType ="
          + " ${rootFs.fsType} — it is zfs, ext4, or tmpfs for a memory-rooted host"
          + " whose store is a squashfs");

      diskoDisks = cfg.disko.devices.disk or { };
      hasDisko = diskoDisks != { };

      # A disko layout IS an install script — create and mount, generated instead of
      # written — so a host that has one installs through it. A host with neither gets its
      # own disk image written as it is, which needs no recipe at all.
      noDisks = throw ("imagesFor(${toString name}): the #image-*-install endpoints need to"
        + " know which disks they may clear, and this host declares neither a disko layout"
        + " nor install.disks");

      # rpool/root -> rpool: the pool is the first component of the root dataset.
      derivedPool =
        if storage != "zfs" then ""
        else lib.head (lib.splitString "/" rootFs.device);

      installFinal = {
        script = install.script or (if hasDisko then cfg.system.build.diskoScript else null);
        disks = install.disks or
          (if hasDisko then map (d: d.device) (lib.attrValues diskoDisks) else noDisks);
        pool = install.pool or derivedPool;
        encrypted = install.encrypted or false;
        report = install.report or null;
        payload = install.payload or null;
        completion = install.completion or "reboot";
      };
    in
    {
      inherit name slotName;
      # The format-VM's inputs, read from the configuration: the disko layout as DATA (only
      # a host that imports the disko module has one), and the hostId the pool is born with.
      layout =
        if hasDisko then { disko.devices = cfg.disko.devices; } else null;
      hostId = cfg.networking.hostId or null;
      system = host.pkgs.stdenv.hostPlatform.system;
      variants = {
        runtime = extract host // { inherit storage; };
        liveNetboot = extract (host.extendModules { modules = [ modules.liveNetboot ]; });
        liveIso = label: extract (host.extendModules { modules = [ (modules.liveIso label) ]; });
      };
      secrets = { delivery = [ ]; files = [ ]; } // secrets;
      install = installFinal;
    };
in
{
  inherit recordFor;
  imagesFor = args: compose (recordFor args);
}
