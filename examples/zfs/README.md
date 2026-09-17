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
| `install.prepare` | partition, `zpool create`, `zfs create`, mount at `/mnt` — the create path |
| `install.mount` | import the pool and mount it — the never-reformat path, tried first |
| `install.disks` | what a create may clear; with a disko layout this would be read from it |

Both scripts run under the act's own PATH (nix, zfs, util-linux, coreutils); anything
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
fit), probes for an existing pool, creates one only if there is none, plants the key,
installs offline, exports the pool and reboots.

**A second run over an installed machine installs nothing** — the pool is found and
mounted. Replacing an existing system is a separate, explicit act: `install.wipe` as an
exact word on the installer's kernel command line, which is the channel a deploy controls
when it kexecs. `install.wipe=0` is not that word and does not enable it.
