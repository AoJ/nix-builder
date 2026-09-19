# A plain disk host

The simplest complete story: one machine, one disk, an ext4 root, secrets delivered in
the artifact. Everything the composer needs is in [`host.nix`](host.nix); the disk itself
is described once in [`layout.nix`](layout.nix) and serves three purposes — it boots the
host, it formats the target at install, and it provides the slot.

## What this host states

Two things, and that is the whole of `host.nix` beyond the configuration itself:

| stated | value here | why it is not read from the host |
|---|---|---|
| `slotName` | `"secrets"` | a name — the layout's partition label says the same word |
| `secrets.files` | `/sops.age`, from a file on the deploying machine | what belongs in the slot, and where its bytes come from |

The file's `target` is a path **inside the slot**, not on the installed system: this host
mounts its slot wherever it likes and reads from there. `content.file` is one of three
forms — `content.env` takes the bytes from a variable at run time (a deploy running
straight from a flake has no files), and `content.text` carries already-encrypted
material declared in nix.

Everything else comes out of the configuration: the ext4 storage from the root filesystem,
the install script and the disk list from the disko layout, the live variants by
`extendModules`, the machine record for the installer. Having that layout is also what
decides how this host is delivered — through disko's own create script, rather than as a
finished image.

Drop the layout and this same host is delivered as its own disk image instead, written to
the target as it is. One host, two ways of arriving, and the disko layout is what picks
between them — see [../README.md](../README.md).

The disk id (`/dev/disk/by-id/virtio-main`) is the one value you must take from the real
machine, and it is stated once — in [`layout.nix`](layout.nix), which is also what the
install clears. Use a by-id name, never `/dev/sda`: a name that moves between boots is a
name that can clear the wrong disk.

## What it gets

Every endpoint exists for this host — no law removes any:

- `image-raw`, `image-qcow2` — the installed system as a disk, ready to `dd` or boot;
- `image-iso`, `image-kexec`, `image-ipxe` — the same host live, root in RAM;
- `image-<format>-install` — an installer that puts this host on the declared disk;
- `image-secrets-<vfat|iso|json>` — the secrets as a sidecar instead of in the slot;
- `image-personalize` — phase 2.

## The sequence

    nix build                            # phase 1: the image, cacheable, secret-free
    nix run .#personalize -- ./result    # phase 2: the slot gains the key
    # dd the result to the disk, or boot it as a VM

Phase 1 and phase 2 are separate because the first is a cacheable derivation and the
second must never be one — it handles secrets. Between them the artifact is complete but
anonymous: it holds an empty slot and no identity.

To install onto a machine instead of writing the disk directly, personalize
`image-kexec-install` and kexec it; the installer clears the declared disk, formats it
through this same layout, fills the slot the layout provides with the same files, and
leaves the machine on the installed system — which finds them exactly where it would have,
had the image written the slot. That second path replaces whatever was on the disk: an
install is a takeover, not an upgrade.
