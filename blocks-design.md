# Blocks — design

Design only. No implementation. The endpoint set, the vocabulary and the laws this serves are
`wip/plan-image-build.md`; nothing here restates them. Proposed code lives in
`wip/blocks-poc/` and is referenced by path, never inlined.

A block has a declared input, a declared output, its own tests, and keeps its implementation
details inside. It does not import another block. Verified on `blocks/image` — see
`wip/blocks-poc/blocks/image/`.

## The blocks

| block | in | out |
|---|---|---|
| `image` | a system, a format | the artifact, and the toplevel that went into it |
| `install` | the host to install | a system that installs it |
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

Also inside: the artifact face of the slot — reserving it, formatting it, leaving it empty.

## install

Wraps a host in an OS that unpacks it (aoj: *install je předvěsek pro image, obalí host install
funkcí*). Its input is a system and its output is a system, so it sits **before** `image` and the
`-install` half of the endpoint set is `image(install(host), format)` — the format does not know
that it is packing an installer.

Two things are in flight and they are different: the system being installed, and the system doing
the installing. The block holds both; the caller states which host is to be installed.

Inside: disk preparation, the install itself, what runs it at boot, and where the installed
system's key lands on the target. The installer's own slot belongs to the artifact, so it is
`image`'s (above).

## store

Store paths in, a filesystem holding them out — with the nix database **registered**, not just
the paths copied. Shape is `ext4` or `squashfs`.

This is a block rather than a detail of `image` because three consumers need the same thing and
have each got it wrong separately: a disk image's root, a netboot/live squashfs, and the closure
an offline installer carries. A store whose paths are present but unregistered answers "not
valid" about a path in front of it, and anything copying a closure out of it refuses to start.

Open: whether this is its own block or lives inside `image`. It is the smallest piece with a
test that has repeatedly been worth having, which argues for a block; it is also never asked for
on its own, which argues against.

## secrets

Files in, a sidecar out, named by the filesystem the consumer will mount. Nothing boots and there
is no partition table.

`#image-secrets-json` does not fit that sentence — JSON is not a filesystem. Either the block's
medium is "what the consumer reads", not "what it mounts", or json is not a sidecar. Open.

## personalize

Phase two: a finished artifact gains the files its slot is for. Separate from `image` on purpose —
phase one is cacheable and secret-free, phase two must not be cached.

Inside: how to find the slot in each format, and the refusals. A private key written to the wrong
offset is not recoverable by noticing afterwards, so this block refuses rather than guesses.

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

1. `store` as a block, or inside `image`.
2. `#image-secrets-json` against "named by the filesystem the consumer mounts".
3. Who holds the slot descriptor. The plan gives it to the storage layout; `iso` has no layout,
   and `kexec` / `ipxe` have no filesystem.
4. Whether `install` takes the host as a system or as its closure.
