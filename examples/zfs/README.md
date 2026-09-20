# A zfs server

A zfs pool is a kernel object with its own GUID, hostid and feature flags — it cannot come
out of userspace assembly. But there IS a kernel that can make one: the format-VM, a VM on
the runner's own architecture. So for a zfs host the runtime disk image is real (law L2, as
amended) — `image-raw` formats a blank disk from this host's disko layout in that VM and
injects the closure as data, no target-arch code, so an aarch64 image builds on an x86 box.
The one thing it will not build is an *encrypted* pool: that stays install-only (L3), see
[`../zfs-encrypted/`](../zfs-encrypted/).

## What this host states beyond the plain case

The configuration says `fileSystems."/" = { device = "rpool/root"; fsType = "zfs"; }`, and
that alone tells the builder the storage is zfs and the pool is `rpool`. What it cannot
tell is how that pool is laid out — so this host imports `builder.lib.diskLayoutZfs` next
to disko's module, exactly as the ext4 host imports `diskLayout`:

| stated | what it is |
|---|---|
| `builder.lib.diskLayoutZfs { device; slotName; }` | ESP, the vfat slot, the rest one pool with a legacy root — plain disko data in this configuration, overridden like any option |
| the zfs boot facts | `networking.hostId`, `forceImportRoot`, `devNodes`, and the root/boot mounts — a zfs root's runtime particulars the host keeps (the template leaves `enableConfig` off) |

Having a disko layout is what makes ONE declaration feed three things: the install runs
disko's own create script through it, the format-VM formats the runtime image from the same
data, and the disk list a create may clear comes from it. Nothing hand-rolled — the pool
the installed system imports was made by the same disko every other target uses.

## Three installers, one host

The wrapper is an operational choice, not a property of the host — the builder offers all
of them and a deploy picks:

| endpoint | rooted | for |
|---|---|---|
| `image-kexec-install` | memory | a machine that is already running: deploy kexecs into it |
| `image-raw-install` | its own disk | a USB stick installing a **different** disk; carries the closure RAM-independently |
| `image-raw-install-inmemory` | memory | the closure rides the initrd, so the installer holds no claim on any disk — it may therefore install the very disk it booted from (the one-disk cloud box) |

## The sequence

    nix build                                   # the installer artifact
    nix run .#personalize-kexec -- ./result     # phase 2: key into the installer's slot
    # boot/kexec it on the target machine

What happens on the machine, in order: the installer reads its slot, refuses anything it
cannot carry out (absent disk, a disk holding the running system, a closure that will not
fit, files the slot was supposed to hold and does not), clears the declared disks, runs
this host's script to create the pool, fills the target's slot, installs offline, exports
the pool and leaves.

**A second run replaces what is there.** An install is not an upgrade: installing onto
storage that already holds a system would leave a machine that is half one system and half
another, so the declared disks are cleared every time. Booting this artifact is the intent
— it was put in the machine or kexec'd into it on purpose — and nothing asks again.
