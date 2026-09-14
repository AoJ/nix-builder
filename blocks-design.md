# Blocks — design

The design for the image / install / secrets factory, and for what deploy receives from it. It
absorbs the decisions of `docs/plan-image-build.md` — vocabulary, laws, endpoint set, the two
layers — so it reads standalone; the plan remains the record of MEASURED evidence, the withdrawn
branch's algorithm inventory, and the step order. The contracts are each block's `block.nix`
options — validated `evalModules` interfaces — and the code is `docs/blocks/blocks-poc/`;
both are referenced by path, never inlined.

**Provenance.** Everything marked DECIDED is something aoj stated, in aoj's own words where
possible. Everything else is measured, labelled derived, or open. Nothing else gets to look like
a decision — the withdrawn branch broke this rule once, and the decision had to be restated from
memory after the session that took it was lost.

A block has a declared input, a declared output, its own tests, and keeps its implementation
details inside. It does not import another block. Verified in `docs/blocks/blocks-poc/`: all four
blocks, the store tool, and a composer (`compose.nix`) that drives the full endpoint set over a
hand-assembled host — six test suites, no `nixosSystem` in any of them. Real configurations
enter one directory later, `docs/blocks/tests/`: four hosts spanning the dimensions, the real
extraction and extendModules step, an eval-only gate forcing every endpoint of every host to a
`.drv`, and e2e boots of the assembled artifacts under OVMF/KVM.

## Why blocks

**A block tests every variant of its mechanism, so the mechanism is not what breaks.** A host can
still be broken — it can declare parameters, or a combination of them, that do not go together —
but that is one host failing on its own configuration while the world keeps working. Today it is
the other way round: hosts are green and the world is broken, because what gets tested is a host's
toplevel and not the machinery that has to deliver it.

This is the reason the blocks are cut where they are cut. A test that needs a host cannot cover a
matrix; a test that needs no host can.

## The vocabulary — DECIDED

    bootImage.format   = iso | raw | qcow2 | kexec | ipxe
    runtime.mode       = memory | disk
    runtime.storage    = zfs | ext4 | squashfs
    secrets.delivery   = embedded | sidecar | deploy | external   (a SET, combinable)

The plan's `bootImage.type = runtime | install` survives only in endpoint names: `install` sits
before `image` in the pipe, so `-install` is which pipe the composer builds, not an input any
block takes. `secrets.destination` is gone: it named the slot as a property of the storage
layout, and the slot turned out not to be one — see "The slot".

What the dimensions replace:

| today | becomes | why |
|---|---|---|
| `profileModules { live = true; }` | `bootImage.format` + `runtime.mode` | one flag, five meanings, none of them its name |
| `realization.root.medium` | `runtime.mode` + `runtime.storage` | mixes *where* with *which filesystem* |
| `realization.secretsTransport.kind` | `secrets.delivery` | mixes location with delivery; "sops" is a bundle format, not a transport |
| `host.image.rawImage` / `.diskImage` | gone | the format is what you ask for, not a host flag |
| `realization.delivery.modes` | folds into the dimensions | overlaps both |

**The law under all of it (DECIDED): a switch may never carry more than one meaning.** Where
settings really move together, that is a macro — one thing you set, which sets the others. `live`
deciding five unrelated questions, and `#qcow2` meaning one mechanism on one host and another
elsewhere, are the same defect in a flag and in a name.

## The laws

Consequences of the dimensions, not per-host switches. A host cannot turn them on or off; the matrix
has shape, not exceptions.

DECIDED (aoj):

- **L1 — `format = iso` ⇒ `runtime.mode = memory`, `runtime.storage = squashfs`.** An ISO is
  read-only, so its root is always an overlay in RAM. A ZFS host's ISO simply does not use the
  host's storage declaration. ("prostě není co řešit")
- **L2 — a ZFS pool is created by the install, never by the image.** A pool is a kernel object
  with its own GUID, hostid and feature flags; it cannot come out of the nix store. The
  deliverable for a `storage = zfs` host is an `-install` image, and `#image-raw` /
  `#image-qcow2` for such a host is an **unsupported combination** — a hole the matrix names,
  not an endpoint that quietly means something else. ("necháme jako díru, matice na to ukáže")
- **L3 — encryption is a property of the storage layout, and follows L2.** No `#image-*` is ever
  encrypted. Correctness, not tidiness: a pool created with a store-visible placeholder
  passphrase is compromised for its whole life — `zfs change-key` rewrites neither the master
  key nor the previous wrapped key on disk (measured, in the plan).

Derived:

- **L4 — `format = kexec | ipxe` ⇒ `runtime.mode = memory`.** Same reason as L1: no disk.
- **L5 — `personalize` requires a writable slot in the finished artifact.** Which formats have
  one is measured, not assumed — see the slot's table.

## The endpoint set — DECIDED

One prefix, the same set for every host; a host does not choose which endpoints it gets.

    runtime images   #image-iso   #image-raw   #image-qcow2   #image-kexec   #image-ipxe
    install images   the same five with -install
    sidecars         #image-secrets-iso   #image-secrets-vfat   #image-secrets-json
    phase 2          #image-personalize
    store artifacts  #closure   #derivation             (the host as it runs)
                     #closure-live   #derivation-live   (the memory-rooted variant)

A sidecar is named by how the consumer takes it: a filesystem it mounts (`iso`, `vfat`) or a
format it reads (`json`) — there is no partition table and nothing boots. `image` means "an
artifact you get as a file", not "something that boots" (aoj: "image nemusí být jen boot").
`json` is a full member of the set (aoj, 2026-09-14) — earlier drafts dropped it repeatedly,
which is why it sits in the DECIDED list and under the compose test, not in an open item.

`#closure` / `#derivation` are keyed on the VARIANT, not the format: `#image-raw` and
`#image-qcow2` of one host hold the same closure, while `#image-iso` holds a different one
because L1 changes the configuration. A host having several toplevels is visible in a name
instead of hidden in a flag.

**Every host exposes the whole set, and every endpoint is under test** — an endpoint that exists
only for the host that needs it is an endpoint nobody notices breaking.

### The two layers — DECIDED

**`#image-<format>` is the HOST, in that format.** The full host closure, packed so a firmware, a
running kernel or a network card can start it. The host is an ordinary OS and declares nothing
for this; `#image-iso` is what turns it into a live ISO. Its value is the delivery that has no
automation (pi5, iris), debugging, and testing.

**`#image-<format>-install` is that same closure with a wrapper that installs it instead of
starting it.** The installer carries the host's closure — always, in every format. That is not a
size trade-off to re-litigate per endpoint: **offline installation is the whole point of the
`-install` layer** — an artifact that must be completed over a network afterwards is not an
offline installer. Two intended consequences: `deploy-lib.sh`'s `phase_copy` becomes redundant,
and it costs LESS memory, not more (≈30% — the closure travels compressed in a squashfs whose
decompressed pages are reclaimable page cache, where `nix-store --import` fills a tmpfs that is
not).

**Phase 1 / phase 2.** Everything above is phase 1: cacheable, shareable, secret-free.
`#image-personalize` is phase 2: the finished artifact gains the files its slot is for, and it
must not be cached.

### The matrix

Backend is assembly everywhere — no VM anywhere in the image path.

| host runtime | `#image-iso` | `#image-raw` / `-qcow2` | `#image-kexec` / `-ipxe` | `#image-*-install` |
|---|---|---|---|---|
| memory / squashfs | yes | yes | yes | yes |
| disk / ext4 | yes (L1) | yes | yes (L4) | yes |
| disk / zfs | yes (L1) | **unsupported (L2)** — use `#image-raw-install` | yes (L4) | yes |

The one hole is a law, not a per-host switch: it is a property of `runtime.storage`, reads the
same for every host that has one, and names its own replacement.

## The blocks

| block | in | out |
|---|---|---|
| `image` | a system, a format | the artifact, and the toplevel that went into it |
| `install` | a closure and how to place it | a system that installs it |
| `secrets` | files, a medium | a sidecar file |
| `personalize` | a finished artifact, files | that artifact with its slot filled |

`#closure` / `#derivation` / `#closure-live` / `#derivation-live` are **not blocks**. They are
names for something a block already returned; naming them costs nothing and building them twice
is what produces a reconstruction that has to be asserted equal to the original.

What the endpoints map to:

| endpoint | is |
|---|---|
| `#image-<format>` | `image(host, format)` |
| `#image-<format>-install` | `image(install(host), format)` |
| `#image-secrets-<medium>` | `secrets(…, medium)` |
| `#image-personalize` | `personalize(artifact, slot, files)` |
| `#closure` / `#derivation` | the host's toplevel, named |
| `#closure-live` / `#derivation-live` | the toplevel `image` returned for a live format |

## The composer

Whoever calls the blocks — `lib/` — is the composer: the one place that knows the host. Blocks do
not know about each other, do not call each other, and never see a host.

**A block's input is derivations and strings, never a configuration.** The boundary is not
policed but made unrepresentable: the composer extracts what a block needs — toplevel, kernel,
initrd, kernelParams, closure, names — and the block is handed nothing a `niximilate.*` could be
read from. The positive proof is the block's own tests, driven from a record assembled by hand
with no `nixosSystem` in it.

Two consequences, derived in the plan and kept:

- **Format is the first decision, not the last.** A live format packs the memory-rooted variant,
  and the variant is a configuration change — so the composer evaluates it before anything enters
  a block, and the extraction sits between the evaluated system and `image`. The pipe's carrier
  changes shape exactly once, at that extraction, and the extraction is written explicitly rather
  than smuggled into a block.
- **The store shape enters from above** (DECIDED). `kexec` / `ipxe` need the store in the initrd
  — there is no disk; `raw` / `qcow2` need a partition — an EFI stub refuses a 1.3 GiB initrd
  (`EFI_OUT_OF_RESOURCES`, measured). The composer picks the shape because it knows which format
  it is asking for, and **`image` validates that the shape it was handed is legal for the format
  it was asked for** — a wrong composition fails at eval, in `image`, instead of at boot on the
  machine. On the `-install` half the shape is the **wrapper's own** (its store carries the
  installer and the host's closure); the target's storage never shapes it, which is why the L2
  hole does not exist there — and why the composer names that hole itself, at eval, for the
  runtime half of a zfs host.

## Tools

Blocks are not fully isolated: some mechanism is shared (the bash tooling, the store algorithm).
Sharing it must not become blocks calling each other, so the two are separated by what they are,
not by convention.

| | block | tool |
|---|---|---|
| answers to an endpoint | yes | no |
| has an intent | "give me the host in this format" | "turn these paths into a filesystem" |
| what its test covers | the mechanism you are guarding | part of a block's test |
| who calls it | the composer | anyone |

**Dependencies run one way: block → tool. Never block → block, never tool → block.** The graph is
then acyclic by construction rather than by discipline.

To make that unavoidable rather than agreed, **a block imports nothing outside its own
directory**. Its own parts it may split into files freely — nobody else sees them. Tools arrive as
an input, exactly like `pkgs`:

    { pkgs, tools }:

`tools` is to this repo's mechanisms what `pkgs` is to nixpkgs — one set, handed over whole, so no
detail leaks: nobody writes in the composer that `image` needs the store, any more than they write
that it needs mtools. The check is then trivial: **an import under `blocks/` that leaves the
block's own directory is an error.** No detection of cross-calls is needed, because a block has
nothing to reach another block with.

The cost: one place assembles `tools`, and it is the only privileged place in the structure. Only
tools may go in it. A block placed there would let a block reach a block, and the rule falls. It
is also the one spot that reaches into the repo's shared lib: `mkBashTool` (and the bash helper
lib it prepends) enters here, so every tool script is shellcheck-gated at build.

The set as the PoC stands: `bashTool` (mkBashTool bound to `pkgs`), `ids` (identity from a name),
`fatImage` (manifest → FAT filesystem — the ESP, the slot, and the vfat sidecar are one
mechanism), `gptDisk` (partition images → GPT disk, layout emitted as JSON), `store` (below).

## Reproducibility and identity

Two properties of every artifact a block hands over, and they are not the same property.

**Two builds of one image are the same bytes.** Nothing gives this for free: every filesystem
tool stamps a wall clock or generates an id unless told not to.

**Two different images are never the same identity.** Every uuid, guid and volume id is derived
from the image's name — not generated, and not a constant. A constant satisfies the first
property and violates this one: it is deterministic AND wrong, because two images then answer the
same `by-uuid` lookup, and that shows up on a machine rather than in a build. nixpkgs ships
exactly that — every ISO carries label `EFIBOOT` and fs uuid `1234-5678`, which is why a by-label
lookup cannot be trusted there.

Nix cannot gate the first for us: two builds of one derivation are the same store path, so a
non-deterministic builder is invisible to it. It is gated where everything else is — in the test
that belongs to whatever produced the artifact — by forcing a second build of the same inputs and
comparing.

**Both properties are per-architecture.** A native and an emulated build of one squashfs come out
the same size and not the same bytes, so "the same bytes" holds for two builds on the same
architecture and is not a claim about an artifact built in two places. That matters for the
aarch64 hosts, whose images are built emulated or on a foreign builder.

## image

Packs one system into one format. Everything about how a format is made is inside.

The input is a format and one extracted system — the variant that matches the format, which the
composer already evaluated. The block cannot tell a host from an installer from a live variant,
and does not need to: it packs what it was handed, and validates that the store shape it received
is legal for the format (see "The composer").

**The output carries the toplevel that was packed**, alongside the file. That is what makes
`#closure-live` a lookup rather than a second evaluation that has to be proven identical to the
first.

Inside, not in the caller: the EFI removable-media path per architecture, the bootloader binary
per architecture, loader entries, GPT type codes, partition sizes and offsets, filesystem
parameters, and which mechanism a given format is built by. `kexec` and `ipxe` are one payload
with two loader descriptors — that is one branch inside the block, not two formats.

How the formats are made, as built: `raw` / `qcow2` are the GPT assembly — ESP, store partition,
optional slot partition; `qcow2` is the same disk in a different envelope. `iso` puts the kernel,
initrd and loader entries INSIDE the ESP image, points an El Torito record at it, and marks the
same image in a GPT so the file also boots dd'd to a stick (the nixpkgs pattern); the iso9660
itself carries the squashfs store and the slot file. `kexec` / `ipxe` are one tree — kernel, the
caller's initrd with the store cpio appended, and both loader descriptors.

## install

Wraps a host in an OS that unpacks it. Its output is a system, so it sits **before** `image`,
and the `-install` half of the endpoint set is `image(install(host), format)`
— the format does not know it is packing an installer.

**Its input is a closure, not a system**. Measured against what the current
installer actually consumes — a disk-preparation step, a mount step, the toplevel, the pool name,
and where the key lands — that is five extracted values rather than a configuration. The
difference is not in what the block can do; it is that a closure can be tested without a host and
a configuration cannot. The block is deliberately asymmetric: derivations and strings in, a system
out.

Two things are in flight and they are different: the system being installed, and the system doing
the installing. The block builds the second and carries the first. **What gets installed is always
the host as it runs**: a live format on an `-install` endpoint shapes only the wrapper's
packaging, never which closure is carried — the PoC's compose test is what caught the composer
carrying the live variant instead.

Two SLOTS are in flight too, with different lifetimes, and one field cannot carry both: the
installer's OWN slot — where the install-time key is read from, `image`'s input when the
installer is packed — and the place the installed host's key lands on the target it just created,
which is this block's `keyDestination` input. The contract keeps them apart.

## store — a tool, inside image

Store paths in, a filesystem holding them out — with the nix database **registered**, not just the
paths copied. A store whose paths are present but unregistered answers "not valid" about a path in
front of it, and anything copying a closure out of it refuses to start.

It belongs to `image` and is reached as a tool, not as a block: `image` is the
only thing that asks for it as part of an endpoint, while a tool still carries its own test.

**Registration is two mechanisms, not one**, because the database does not live where the store
does — the store is at `/nix/store`, the database at `/nix/var/nix/db`:

| shape | where the database comes from |
|---|---|
| ext4 (writable) | both live on one writable filesystem, so the database is written **at build time** and the image carries it |
| squashfs (read-only) | the image is mounted read-only at `/nix/store`, and the database's place is a tmpfs that boots empty — so the image carries only a dump, and a **unit loads it at every boot** |
| cpio (netboot) | the paths land on the initramfs tmpfs, but the database still boots empty — the archive carries the dump at the same constant path, and the same kind of unit loads it |

With a `profile` toplevel the ext4 shape is a bootable NixOS ROOT, not just a store filesystem:
generation link + `system` profile symlink (what `systemd-boot-builder` reads on the first
switch), `/etc/NIXOS`, and the FHS mount points. Without one it stays a bare store. The
distinction is the tool's, not the caller's to assemble: both halves sit on one writable
filesystem or neither does.

### The unit is not the block's, and not the chain's

A squashfs store needs that unit, and the tool cannot give it — but it does not follow that the
chain has to carry a configuration. The unit belongs to **whatever module declares the read-only
store**, because those are not two properties but one: a configuration that says
`fileSystems."/nix/store"` is a squashfs does not work without it, the way a mount does not work
without a filesystem.

The alternative is not merely unattractive, it is a cycle. The tool takes the toplevel as its
input; if it returned the unit, the unit would have to be in the configuration that toplevel was
built from:

    configuration → toplevel → store(toplevel) → unit → configuration

nixpkgs resolves it the same way: the unit sits in the configuration statically and does not
depend on the squashfs at all, reading a constant path that `make-squashfs.nix` writes into every
image. **Both sides take that path from nixpkgs, not from each other**, which is why no dependency
runs between the tool and the module.

What remains a real agreement is that constant, spanning build time and boot — so it is asserted
in the tool's own test rather than left to hold by habit.

Status: nixpkgs supplies both halves for the live ISO and for netboot. For the appliance, the
withdrawn branch has the unit and **`dev` has none at all** — a real gap, not a design question,
and the implementation already exists to carry over.

## secrets

Files in, a sidecar out. Nothing boots and there is no partition table.

A sidecar is data placed beside an image or file for the consumer to take. **Whether the consumer
mounts it or reads it is a property of the medium, not part of what a sidecar is**.

The block is one producer behind `secrets.delivery`, which is a SET on the host (DECIDED):
`embedded` (the key rides in the artifact; `personalize` puts it there), `sidecar` (this block),
`deploy` (pushed), `external` (a vault, instance metadata). Combining them is normal. A host that
declares no secrets gets a silent no-op everywhere; **nothing may key off "the host has a
bundle"** — that is how pi5-inmemory ended up with sops-boot wired beside its baked partition,
pointing at a `/var/secrets/sops.age` that nothing ever writes.

**A declared delivery must have a producer.** Six places in the repo currently implement "the
machine must end up with its key" and none knows about the others; a declaration whose producer
was left behind is how a host booted without an identity. Naming a producer for every member of
the set is the composer's job, and a member without one fails at eval — the same shape as the
slot's first check.

For an `-install` image the consumer is the **install script**, not the target OS. That is why L2
costs nothing: the installer's own slot is a plain, writable, well-known place, and the pool is
created on the target with the real passphrase — no placeholder key in a cacheable derivation.

## personalize

Phase two: a finished artifact gains the files its slot is for. Separate from `image` on purpose —
phase one is cacheable and secret-free nix-way process, phase two must not be cached. Its output
is a runner, not a derivation — a secret in a derivation is a secret in the store.

Inside: how to find the slot in each format, and the refusals. A private key written to the wrong
offset is not recoverable by noticing afterwards, so this block refuses rather than guesses —
and nothing is copied until every check has passed:

1. **the artifact carries the declared slot** — and an empty result says exactly that, not "no
   such file";
2. **the offset really holds a filesystem** — a cheap second opinion on the offset arithmetic,
   and the reason `image` leaves the slot formatted;
3. **the key belongs to this host** — its public half is a recipient of the host's own bundle.
   Planting another host's key otherwise surfaces as an undecryptable boot on a machine that may
   only have a serial console. A bundle the check cannot read is a named refusal, not a skipped
   check: committed bundles are YAML on some hosts and JSON on others. The bundle and the key's
   target arrive as the block's input (`recipientCheck`) — it cannot know the host's;
4. **read back what landed**, out of the artifact, and re-derive the public half.

## The slot

A slot has two faces — a place in the artifact, and a place the running system sees — and no
single block owns both. `image` cannot own it outright: it does not know a host's storage
topology and must not reach into it.

What the faces ARE is fixed by the format:

| format | artifact face — where a tool writes | runtime face — how the booted system reads it |
|---|---|---|
| iso | a file at a path inside the iso9660 | loop mount of `${sysroot}/iso/<path>`, `neededForBoot` |
| raw / qcow2 | a GPT partition, found by NAME | mount of `/dev/disk/by-partlabel/<name>` |
| kexec / ipxe | an appended cpio segment in the initrd | the file simply exists at `/` in the initramfs |

For `iso` the slot is a file and not the isohybrid partition, because that partition is not a
handle: a SATA cdrom exposes no partitions at all, virtio does, and a second disk shifts the
names (measured, in the plan). The offset is read out of the finished image
(`xorriso … report_lba`), never bookkept at build time.

The two faces enter the pipe at different points: the **runtime face** is a payload
transformation — it adds a mount to the system, so it happens before `image`, exactly like
`install`; the **artifact face** is `image`'s input — "reserve a partition named X of size Y",
"place a file at path Z" — and nothing more. `neededForBoot` on the runtime mount is
load-bearing, not an optimisation: `sops.useSystemdActivation` is false on c, ax and iris, so
sops-nix decrypts during activation, when the only filesystems are the ones stage 1 mounted.

**The rule: whoever owns the shape of the storage provides the slot.** Where
there is an fs layout, the layout provides it. Where there is none — `iso` has no layout,
`kexec` / `ipxe` have no filesystem at all — `image` provides it, because it is already making
that shape.

Today that first half has no executor: the only layout is zfs, and a zfs host has no
`#image-raw` to put a slot in — the pool comes from the install, so the combination is a hole the
matrix names. An ext4 layout does not exist yet. So **in practice `image` provides every slot**,
and the rule's other half is written down for the layout that will want it, not for one that does.

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

The second is only reachable if the producer leaves a filesystem where the slot is, rather than a
hole — a hole answers no question about whether the offset is right, and a private key written to
the wrong offset is not recoverable by noticing afterwards. So `image` reserves the slot, formats
it, and leaves it empty: empty is what keeps phase one cacheable and secret-free, formatted is
what lets phase two refuse.

## What deploy is left with

Deploy is not a block; **it is the thing that connects blocks** (DECIDED). It picks the endpoint
an operation consumes and gets it to the machine; the mapping of operation to artifact is in the
plan and does not change here. No block knows deploy exists.

## What green means

The block layer exists to move testing off hosts and onto mechanisms, so the gates are part of
the design, not the test author's taste.

- **A block's tests are a matrix over its contract** — format × store shape × slot — and no host
  appears in any of them. Every test drives the block from a record assembled by hand; that the
  record CAN be assembled by hand is the proof the block reads no configuration.
- **Determinism is forced, because nix cannot see it**: two builds of one derivation are the same
  store path, so each builder runs twice inside one derivation and the outputs are compared.
  Identity is the twin gate: two names must yield two ids. Both claims are per-architecture.
- **Tests read names out of the artifact under test** rather than restating them, so a test
  cannot agree with itself. A refusal is asserted as "wrote nothing" (`test ! -e out`), not as
  "exited non-zero". `personalize` is tested with a fixture bundle encrypted to a throwaway key —
  the smallest substitution that keeps the whole chain real. A qcow2 round-trips back to raw and
  is compared against the source; a netboot payload boots under `-kernel`/`-initrd` with no disk
  attached at all.
- **Per-host checks stay what they are: the last gate before a deploy** — this host, at its
  pinned revision. Attaching a feature's test to every host that enables it is the deploy gate's
  rule; reusing it as feature testing is what the withdrawn branch got wrong — four hosts each
  spending ten VM-minutes to prove one mechanism, and zero coverage of the mechanism's own switch
  combinations. The whole cycle is covered by an e2e attached to no single host.
- **The e2e's witness is the booted system itself**: an assembled artifact boots under OVMF/KVM
  and a marker unit prints what only a running system can prove onto the serial console — that
  userspace came up, and what the slot really holds (empty on a pristine image, the planted
  key's own public half after personalize). The test hosts are throwaway configurations that
  exist for the matrix, not production hosts wearing a second hat.
- **`apps` must be forced at eval.** Both breakages the withdrawn branch shipped lived in `apps`,
  which neither `#drv-diff` (toplevel only) nor the check suite (checks only) evaluates. The
  check is eval-only — it discards the string context, asking what the names are without asking
  for the things to be made.

## Open

1. The slot's descriptor — what a layout states, and what `image` reads it from — and the slot's
   OWNERSHIP: the plan records aoj deciding "the caller composes the slot; no module declares
   one", while this design gives the slot to whoever owns the storage shape. The two coincide
   while `image` provides every slot; the divergence becomes real when an ext4 layout arrives.
2. Whether a validation gate is wanted beyond the two checks above, and where it sits.
3. What belongs in `tools` besides the bash tooling and the store.
4. The self-install RAM bound wants an eval-time assertion: closure size against the tmpfs cap —
   a live ISO's `/` and `/nix/.rw-store` each default to 50% of RAM and share the same pages.
