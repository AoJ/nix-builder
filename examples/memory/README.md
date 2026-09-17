# A memory-rooted appliance

The root lives in RAM and the store is a read-only squashfs on the disk. A squashfs store
is generated FROM a filesystem, which is what the image does — `nixos-install` populates
one instead, so it cannot produce this shape at all (law L6). The consequence is the
point of this example: **this host has no installer**. Every `-install` endpoint is a
hole that refuses at eval, and the deliverable is the runtime image itself.

Updating such a machine means shipping a new image, not running an install.

## What this host provides

| field | value here | note |
|---|---|---|
| the read-only store module | `modules.readOnlyStore { device = …; }` from `lib.mk` | the tmpfs root, the squashfs mount, and the nix database load at boot |
| the storage | **not stated** | the tmpfs root in the configuration already says it |
| `secrets` | **not stated** | no delivery at all is a valid declaration |
| `install` | **absent** | nothing reads it, so nothing has to be invented — a host is only held to what its own endpoints need |

The store partition is found by partition label (`nixos`), which is what the image writes —
the module and the image agree through that one name.

A host that declares no secrets still gets every secrets and personalize endpoint; they
are silent no-ops. That is deliberate: nothing in the system may key off "this host has a
bundle", because a host whose delivery was quietly dropped is exactly how a machine ends
up booting without an identity.

## The sequence

    nix build             # the appliance image: ESP + read-only store
    # dd it to the device, or boot it as a VM; nix build .#netboot for the same over PXE
