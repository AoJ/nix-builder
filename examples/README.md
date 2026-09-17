# Examples

These exist to answer two questions: **what does a host have to provide**, and **where
does each of those things come from**. Each directory is a filled-in form of the host
record; the form itself — every field, its type, and what reads it — is
[`lib/host-record.nix`](../lib/host-record.nix), which the composer validates every
record through. Read that for the contract, read these for what a real host looks like.

They are also runnable (`nix build`), but that is not the point of them.

| example | the host it describes | what it gets |
|---|---|---|
| [`ext4/`](ext4/) | plain disk host, disko layout owns the disk and the slot | every runtime image, every installer, sidecars, phase 2 |
| [`zfs/`](zfs/) | zfs server — the pool is created by the install (L2) | installers only; the runtime disk images are holes |
| [`zfs-encrypted/`](zfs-encrypted/) | the same, encrypted (L3): passphrase at create, key delivered for boot | installers + the phase-2 runner they need |
| [`memory/`](memory/) | squashfs appliance — the image IS the deliverable (L6) | runtime images only; it has no installer at all |

## What you provide, in every case

| you provide | where it comes from | who reads it |
|---|---|---|
| the NixOS configuration | you — it is your host | `lib.extract` turns the evaluated system into the record's `variants` |
| live variants | `extendModules` + a face from `lib.mk`'s `modules` | the iso / kexec / ipxe endpoints, which pack a **different** toplevel |
| the disk's stable id | the machine (`ls -l /dev/disk/by-id/`) | the install act — this is the wipe's blast radius |
| `slotName` | you, once — the layout's partition label and the record must say the same word | image (builds the slot), phase 2 (finds it), the installer (reads its own) |
| `install.prepare` / `install.mount` | your storage layout — disko's own scripts, or equivalents you write | the install act: create-and-mount, and the never-reformat mount |
| secret **paths** | your vault, at phase-2 run time — see below | the phase-2 and sidecar runners, when they run |

Nothing else is implicit. A field this repo does not read is not in the record, and a
field it does read has no silent default: a record missing one is refused by name, and
only when an endpoint that needs it is actually asked for (an appliance with no
installer never has to invent an `install`).

## Where the secrets come from

**The builder never generates a key.** It carries, places and verifies them; producing
them is the operator's, and the design keeps it that way so no secret can end up in the
nix store. Concretely, once per host:

    age-keygen -o host.key                 # the host's identity — keep it in your vault
    age-keygen -y host.key                 # its public half: add as a sops recipient
    sops --encrypt --age "$pub" secrets.yaml > bundle.yaml

Then `secrets.files[].source` and `secrets.bundle` in the record are the paths **where
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
