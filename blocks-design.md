# Blocks — design

Design only. No implementation. The endpoint set, the vocabulary and the laws this serves are
`wip/plan-image-build.md`; nothing here restates them. Proposed contracts are
`docs/blocks/blocks-contracts.nix`, proposed code `docs/blocks/blocks-poc/` — referenced by
path, never inlined.

A block has a declared input, a declared output, its own tests, and keeps its implementation
details inside. It does not import another block. Verified on `blocks/image` — see
`docs/blocks/blocks-poc/blocks/image/`.

## Why blocks

**A block tests every variant of its mechanism, so the mechanism is not what breaks.** A host can
still be broken — it can declare parameters, or a combination of them, that do not go together —
but that is one host failing on its own configuration while the world keeps working. Today it is
the other way round: hosts are green and the world is broken, because what gets tested is a host's
toplevel and not the machinery that has to deliver it. (aoj, 2026-09-13.)

This is the reason the blocks are cut where they are cut. A test that needs a host cannot cover a
matrix; a test that needs no host can.

## The blocks

| block | in | out |
|---|---|---|
| `image` | a system, a format | the artifact, and the toplevel that went into it |
| `install` | a closure and how to place it | a system that installs it |
| `store` | store paths, a shape | a filesystem holding them, with a valid nix DB |
| `secrets` | files, a medium | a sidecar file |
| `personalize` | a finished artifact, files | that artifact with its slot filled |

`#closure` / `#derivation` / `#closure-live` / `#derivation-live` are **not blocks**. They are
names for something a block already returned; naming them costs nothing and building them twice
is what produces a reconstruction that has to be asserted equal to the original.

## image

Packs one system into one format. Everything about how a format is made is inside.

The input is a system and a format. The format decides the variant, so the caller does not pass
one: `iso` / `kexec` / `ipxe` produce the live variant through the generator, `raw` / `qcow2`
produce the host's own runtime. (aoj, 2026-09-13: the host is an ordinary OS; `#image-iso` is what
turns it into a live ISO.)

**The output carries the toplevel that was packed**, alongside the file. That is what makes
`#closure-live` a lookup rather than a second evaluation that has to be proven identical to the
first.

Inside, not in the caller: the EFI removable-media path per architecture, the bootloader binary
per architecture, loader entries, GPT type codes, partition sizes and offsets, filesystem
parameters, and which mechanism a given format is built by. `kexec` and `ipxe` are one payload
with two loader descriptors — that is one branch inside the block, not two formats.

## install

Wraps a host in an OS that unpacks it (aoj: *install je předvěsek pro image, obalí host install
funkcí*). Its output is a system, so it sits **before** `image`, and the `-install` half of the
endpoint set is `image(install(host), format)` — the format does not know it is packing an
installer.

**Its input is a closure, not a system** (aoj, 2026-09-13). Measured against what the current
installer actually consumes — a disk-preparation step, a mount step, the toplevel, the pool name,
and where the key lands — that is five extracted values rather than a configuration. The
difference is not in what the block can do; it is that a closure can be tested without a host and
a configuration cannot. The block is deliberately asymmetric: derivations and strings in, a system
out.

Two things are in flight and they are different: the system being installed, and the system doing
the installing. The block builds the second and carries the first.

## store

Store paths in, a filesystem holding them out — with the nix database **registered**, not just
the paths copied. A store whose paths are present but unregistered answers "not valid" about a
path in front of it, and anything copying a closure out of it refuses to start.

The constraint that decides where this belongs: **registration is two different mechanisms, not
one.**

| shape | where the database comes from |
|---|---|
| ext4 (writable) | loaded into the image at **build** time |
| squashfs (read-only) | the image carries only the dump; it is loaded **at boot**, by a service |

So the squashfs half is not a file — it is a file *plus a unit in the configuration of the system
that runs from it*. A block that produces a file cannot supply the second half.

Consumers, and who builds their store today:

| consumer | shape | built by |
|---|---|---|
| a disk image's root | ext4 | this repo |
| the in-memory appliance | squashfs | this repo |
| a live ISO | squashfs | nixpkgs |
| netboot (kexec / ipxe) | squashfs | nixpkgs |
| the closure an offline installer carries | — | install |

Open, with a recommendation: **not a block.** The ext4 branch is inside `image`; the squashfs
branch is a pair whose second half belongs to the configuration of the system that boots it, and
for ISO and netboot nixpkgs already owns both halves.

## secrets

Files in, a sidecar out. Nothing boots and there is no partition table.

A sidecar is data placed beside an image for the consumer to take. **Whether the consumer mounts
it or reads it is a property of the medium, not part of what a sidecar is** (aoj, 2026-09-13), so
`json` is a medium like `iso` and `vfat`.

## personalize

Phase two: a finished artifact gains the files its slot is for. Separate from `image` on purpose —
phase one is cacheable and secret-free, phase two must not be cached.

Inside: how to find the slot in each format, and the refusals. A private key written to the wrong
offset is not recoverable by noticing afterwards, so this block refuses rather than guesses.

## The slot

A slot has two faces — a place in the artifact, and a place the running system sees — and no
single block owns both. `image` cannot own it outright: it does not know a host's storage
topology and must not reach into it (aoj, 2026-09-13).

**The rule (aoj, 2026-09-13): whoever owns the shape of the storage provides the slot.** Where
there is an fs layout, the layout provides it. Where there is none — `iso` has no layout,
`kexec` / `ipxe` have no filesystem at all — `image` provides it, because it is already making
that shape.

The rule is not enforced in general, and it does not need to be: **it is conditional on the host
asking for it.** A host that declares no embedded delivery owes nothing. A host that declares one
and has no slot is a host whose parameters do not go together — one host failing, not a broken
mechanism, which is the distinction the whole design rests on.

The check is the same wherever the slot came from — *is a slot available?* — which is the same
shape as the pipe: the consumer validates what it received and does not care who produced it.

There are **two checks and they cannot be merged**, because each catches a different failure:

| who | when | catches |
|---|---|---|
| `image` | eval | the host asked for embedded and nobody declared a slot |
| `personalize` | over the finished artifact | the slot is declared but is not in the artifact, or holds no filesystem |

The first cannot catch a build that drifted from its declaration; the second cannot run at eval,
because it works on a finished file.

## What the endpoints map to

| endpoint | is |
|---|---|
| `#image-<format>` | `image(host, format)` |
| `#image-<format>-install` | `image(install(host), format)` |
| `#image-secrets-<medium>` | `secrets(…, medium)` |
| `#closure` / `#derivation` | the host's toplevel, named |
| `#closure-live` / `#derivation-live` | the toplevel `image` returned for a live format |

## What deploy is left with

Deploy binds: it picks the endpoint an operation consumes and gets it to the machine. The mapping
of operation to artifact is in the plan and does not change here. No block knows deploy exists.

## Open

1. `store` as a block, or inside `image` — recommendation above, not decided.
2. The slot's descriptor: what a layout states, and what `image` reads it from.
3. Whether a validation gate is wanted beyond the two checks above, and where it sits.
