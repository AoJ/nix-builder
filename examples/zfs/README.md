# A zfs server

A zfs pool is a kernel object with its own GUID, hostid and feature flags — it cannot
come out of the nix store. So for a zfs host the image is not the deliverable: **the
installer is** (law L2). Asking this host for `image-raw` or `image-qcow2` does not
produce something subtly wrong, it refuses at eval with the law named.

## What this host states beyond the plain case

The configuration says `fileSystems."/" = { device = "rpool/root"; fsType = "zfs"; }`, and
that alone tells the builder the storage is zfs and the pool is `rpool`. What it cannot
tell is how that pool comes into existence — a pool is not a disko layout — so this host
states its own recipe:

| stated | what it is |
|---|---|
| `install.prepare` | the install script: partition, `zpool create`, `zfs create`, mount at `/mnt` |
| `install.disks` | what the install clears; with a disko layout this would be read from it |

Stating that script is also what picks this host's delivery: a host with a recipe carries a
closure and installs through it, a host without one gets its own disk image written as it
is. The script runs under the act's own PATH (nix, zfs, util-linux, coreutils); anything
else is spelled absolutely, as in `host.nix`.

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
