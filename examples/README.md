# Examples

These exist to answer two questions: **what does a host have to provide**, and **where
does each of those things come from**. Each directory hands one evaluated NixOS system to
`builder.lib.imagesFor` and gets the whole endpoint set back — so what you see in a
`host.nix` is exactly the part a configuration cannot state, and nothing else.

And each one is BOOTED by the suite — the very file you copy, not a parallel test host — so
both halves are proven: the host produces its endpoints, AND it comes up and reads its own
slot. See [How they stay true](#how-they-stay-true).

| example | the host it describes | what it gets |
|---|---|---|
| [`ext4/`](ext4/) | plain disk host, the layout template owns the disk and the slot | every runtime image, every installer, sidecars, phase 2 |
| [`zfs/`](zfs/) | zfs server — the pool is made in a runner-arch VM from the host's layout | every runtime image (the format-VM builds `image-raw`), every installer, phase 2 |
| [`zfs-encrypted/`](zfs-encrypted/) | the same, encrypted (L3): the runtime image is a hole, the pool is created at install | installers + the phase-2 runner they need |
| [`memory/`](memory/) | squashfs appliance — the image IS the deliverable (L6) | runtime images only; it has no installer at all |

## What is read from the host, and what you state

`imagesFor` reads everything the configuration already knows. You state the rest.

| read from the configuration | how |
|---|---|
| the storage | `fileSystems."/".fsType` — zfs, ext4, or tmpfs for a memory-rooted host |
| the root mode | the same fact: a tmpfs root is what memory-rooted means |
| the machine | kernel, module sets, firmware — so the installer boots where the host boots |
| the live variants | `extendModules` with our faces, because a live format packs a **different** toplevel |
| the artifact name | `networking.hostName` |
| the install script | disko's own create script, when the host has a disko layout |
| the disk list | the layout's own devices |
| the pool | the first component of a zfs root's dataset (`rpool/root` → `rpool`) |

| you state | why it cannot be read |
|---|---|
| `slotName` | it is a name, and the layout's partition label must say the same word |
| `secrets.files` | what belongs in the slot, and where its bytes come from — see below |
| `install.script` / `disks` | only when the layout is not disko — a hand-made zfs pool has no layout to read |
| `install.encrypted` | a decision about the pool, not a statement the configuration makes |
| `install.completion` | how the machine leaves the install; `kexec` is what a stick left in the machine cannot turn into a loop |

Nothing is guessed. What cannot be derived is refused **by name** when something asks for
it — and only then: a host with no install script keeps every other endpoint, and its
`-install` ones say what is missing instead of vanishing from the set.

## What an install delivers

An install is how a system gets onto a machine, and it is a takeover — the machine may
have been running anything. **What is delivered comes in two shapes, and this one
declaration picks it:**

| shape | when | what reaches the machine |
|---|---|---|
| `image` | the host describes no disk layout | its own disk image, written as it is — bit for bit what was tested, and it may hold any operating system at all |
| `script` | the host describes its disk in disko | the store paths, installed through disko’s own script — blocks never reads the layout, it runs it |

A host that must own a disk but has nothing particular to say about it imports
`builder.lib.diskLayout` in its configuration — ESP, slot, ext4 root — and is then simply
the second case, with no special handling anywhere. See [`ext4/`](ext4/).

**An install replaces what is on the declared disks, every time.** It is not an upgrade:
installing onto storage that already holds a system would leave a machine that is half one
system and half another. Disks the host did not declare are never touched, and a disk the
running system lives on is refused outright.

## The slot, and what goes in it

The slot is a **folder for this host's secrets**. What they are, what they are for, and
what format they are in is the host's business: the builder carries bytes to a name and
never opens them. It also generates nothing — no keys, no passphrases — so no secret can
originate in, or end up in, the nix store.

A host declares what its slot carries, and where each file's bytes come from:

```nix
secrets.files = [
  # already encrypted, so putting it in the store is fine — your own host data, say
  { target = "/sops.json"; content.text = myHost.secretsBundle; }
  # plaintext: read from the environment when the phase-2 runner RUNS. Nothing is
  # written to the store, and the caller needs no file on disk — which is what a deploy
  # running straight from a flake has.
  { target = "/pool.pass"; mode = "0400"; content.env = "SRV_POOL_PASS"; }
  # a path, for a caller that does have a file
  { target = "/sops.age"; content.file = "/run/secrets/srv/host.key"; }
];
```

`target` is a path **inside the slot**, never on the host's own filesystem: reaching into
a host's storage topology is not the builder's to do. Where the slot is mounted, and what
reads it, the host decides — see [`zfs-encrypted/`](zfs-encrypted/), which unlocks its
pool from a file it put in its own slot, under a name only it knows the meaning of.

An `-install` artifact carries the same slot: the installer takes it over, the host's own
storage scripts read whatever they need from the path the builder publishes
(`builder.lib.paths.installSlot`) while the install runs, and the act then fills the slot
the target's layout provides. So the installed system finds its secrets exactly where it
would have, had the image written the slot.

## How they stay true

Every example is gated by the suite (`../run-all.sh`, `examples:test-example-*`): it is
evaluated against this checkout through the same API the flake exports, and every
endpoint its `flake.nix` names is forced to a `.drv`. So an example cannot drift from the
code, and cannot promise an endpoint the composer would refuse. The `flake.nix` wiring
itself is not evaluated — it points at GitHub on purpose.

But eval is not use. So each example is also BOOTED, as the actual `host.nix` a user copies
— its witness modules threaded through an `extraModules` seam so the copied file stays clean
— by `tests:e2e-example-<name>`: ext4, zfs and memory boot their `#image-raw` and, where they
have a slot, mount it; the encrypted host is INSTALLED first (its `#image-raw` is a hole) and
the target then boots unattended, unlocking the pool with the key the install delivered. An
example that produced a slot no config could mount, or a config that did not boot, fails here
— which is where "it builds" stops standing in for "it works".
