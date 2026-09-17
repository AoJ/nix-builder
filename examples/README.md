# Examples

These exist to answer two questions: **what does a host have to provide**, and **where
does each of those things come from**. Each directory hands one evaluated NixOS system to
`builder.lib.imagesFor` and gets the whole endpoint set back — so what you see in a
`host.nix` is exactly the part a configuration cannot state, and nothing else.

They are also runnable (`nix build`), but that is not the point of them.

| example | the host it describes | what it gets |
|---|---|---|
| [`ext4/`](ext4/) | plain disk host, disko layout owns the disk and the slot | every runtime image, every installer, sidecars, phase 2 |
| [`zfs/`](zfs/) | zfs server — the pool is created by the install (L2) | installers only; the runtime disk images are holes |
| [`zfs-encrypted/`](zfs-encrypted/) | the same, encrypted (L3): passphrase at create, key delivered for boot | installers + the phase-2 runner they need |
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
| the install recipe | disko's own create and mount scripts, and the layout's disk list |
| the pool | the first component of a zfs root's dataset (`rpool/root` → `rpool`) |
| `keyDestination` | sops-nix's `sops.age.keyFile`, when the host has sops-nix |

| you state | why it cannot be read |
|---|---|
| `slotName` | it is a name, and the layout's partition label must say the same word |
| `secrets.*` paths | runtime facts about the deploying machine, not properties of the host |
| `install.prepare` / `mount` / `disks` | only when the layout is not disko — a hand-made zfs pool has no layout to read |
| `install.encrypted`, `poolKeyDestination` | decisions about the pool, not statements the configuration makes |

Nothing is guessed. What cannot be derived is refused **by name** when something asks for
it — and only then: a host with no install recipe keeps every other endpoint, and its
`-install` ones say what is missing instead of vanishing from the set.

## Where the secrets come from

**The builder never generates a key.** It carries, places and verifies them; producing
them is the operator's, and the design keeps it that way so no secret can end up in the
nix store. Concretely, once per host:

    age-keygen -o host.key                 # the host's identity — keep it in your vault
    age-keygen -y host.key                 # its public half: add as a sops recipient
    sops --encrypt --age "$pub" secrets.yaml > bundle.yaml

Then `secrets.files[].source` and `secrets.bundle` are the paths **where
those files will be at the moment phase 2 runs** — on the machine doing the
personalizing, not in the store, not in a derivation. The examples write them as
`/run/secrets/<host>/…` because that is where a deploy typically drops them.

What the builder guarantees in return: phase 2 refuses to plant a key whose public half
is not a recipient of that host's `bundle`. Without that check a wrong key produces a
machine that boots and cannot decrypt anything — often with nothing but a serial console
to find out on.

An encrypted-zfs host adds one more file to the same delivery (its pool passphrase); see
[`zfs-encrypted/`](zfs-encrypted/) for the whole path from vault to unattended unlock.

## How they stay true

Every example is gated by the suite (`../run-all.sh`, `examples:test-example-*`): it is
evaluated against this checkout through the same API the flake exports, and every
endpoint its `flake.nix` names is forced to a `.drv`. So an example cannot drift from the
code, and cannot promise an endpoint the composer would refuse. The `flake.nix` wiring
itself is not evaluated — it points at GitHub on purpose.
