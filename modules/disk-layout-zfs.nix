# The zfs disk layout TEMPLATE: GPT on one disk — an ESP at /boot, a vfat SLOT partition,
# and the rest one pool with a legacy-mounted root dataset. Imported in the host's own
# configuration alongside disko's module, and overridden there like any other option.
#
# Two things it feeds, both from ONE declaration: the install runs disko's own create
# script through it, and the format-VM formats a runtime disk image from the same layout
# data (a pool is a kernel object, so a runner-arch VM makes it — the aarch64 image builds
# on an x86 box, no target-arch code).
#
# enableConfig is OFF on purpose: a zfs root's runtime config has moving parts a host wants
# to state itself (hostId, forceImportRoot, devNodes), so the host keeps its own
# fileSystems and this template does not generate them. disko still gives its create script
# and the device data — which is all the install and the format-VM read.
#
# Encryption (L3) is DATA here: pass `encryption = { keyInstall; keyBoot; }` and the pool
# is created with keyformat=passphrase reading `keyInstall` (the install action mounts the
# slot there, so disko's create finds the delivered passphrase), then the postCreateHook
# repoints keylocation at `keyBoot` — the path the installed system's initrd provides. The
# encrypted RUNTIME image stays a hole (the composer refuses it, L3); only the install path
# ever runs an encrypted create.
# pool and espLabel are REQUIRED, no default: each must AGREE with something the host states
# elsewhere (the root dataset it mounts, the /boot partlabel), so a hidden default here would
# be a second source of that truth — exactly how a host silently drifts into formatting
# storage it then cannot find. espSize/slotSize default because they are standalone sizes
# with no counterpart to drift against.
{ device, slotName ? null, pool, espLabel, espSize ? "512M", slotSize ? "8M"
, encryption ? null, poolPostCreate ? "", slotMount ? null }:
{ lib, ... }:
{
  disko.enableConfig = false;
  disko.devices.disk.main = {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      # The slot partition rides only when the host names a slot (it delivers secrets — an
      # encrypted host always does, for its passphrase). slotName = null: ESP + pool, no slot.
      partitions = {
        # Labels are LOOKUP HANDLES, stated — disko's default is disk-<disk>-<part>, and
        # ESP is what the host's own fileSystems."/boot" mounts by.
        ESP = {
          priority = 1;
          size = espSize;
          type = "EF00";
          label = espLabel;
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; };
        };
        zfs = {
          priority = 3;
          size = "100%";
          label = "zfs";
          content = { type = "zfs"; inherit pool; };
        };
      } // lib.optionalAttrs (slotName != null) {
        ${slotName} = {
          priority = 2;
          size = slotSize;
          label = slotName;
          # A mountpoint makes disko MOUNT the slot at create time (under /mnt during the
          # install), which an encrypted host needs: nixos-install's bootloader step bakes
          # the pool passphrase into the initrd from a file on the mounted slot, so it must
          # be in place before that step. Null leaves the slot unmounted — personalize
          # fills it, the running system mounts it on demand.
          content = { type = "filesystem"; format = "vfat"; }
            // lib.optionalAttrs (slotMount != null) { mountpoint = slotMount; };
        };
      };
    };
  };
  disko.devices.zpool.${pool} = {
    type = "zpool";
    options.ashift = "12";
    rootFsOptions = {
      compression = "on";
      mountpoint = "none";
    } // lib.optionalAttrs (encryption != null) {
      encryption = "on";
      keyformat = "passphrase";
      keylocation = "file://${encryption.keyInstall}";
    };
    # The create reads the passphrase off the install-slot path; the installed system reads
    # it from the initrd path, so keylocation is repointed once the pool exists.
    # poolPostCreate is a consumer hook (a test's witness line, say) run after that.
    postCreateHook = lib.concatStringsSep "\n" (
      lib.optional (encryption != null)
        "zfs set keylocation=file://${encryption.keyBoot} ${pool}"
      ++ lib.optional (poolPostCreate != "") poolPostCreate);
    datasets.root = {
      type = "zfs_fs";
      options.mountpoint = "legacy";
      mountpoint = "/";
    };
  };
}
