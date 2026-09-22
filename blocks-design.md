# Blocks — design

The design for the image / install / secrets factory, and for what deploy receives from it. It
absorbs the decisions of `docs/plan-image-build.md` — vocabulary, laws, endpoint set, the two
layers — so it reads standalone; the plan remains the record of MEASURED evidence, the withdrawn
branch's algorithm inventory, and the step order. The contracts are each block's `block.nix`
options — validated `evalModules` interfaces — and the code is the repository itself;
both are referenced by path, never inlined.

**Provenance.** Everything marked DECIDED is something aoj stated, in aoj's own words where
possible. Everything else is measured, labelled derived, or open. Nothing else gets to look like
a decision — the withdrawn branch broke this rule once, and the decision had to be restated from
memory after the session that took it was lost.

A block has a declared input, a declared output, its own tests, and keeps its implementation
details inside. It does not import another block. Verified at the repository root: all four
blocks, the store tool, and a composer (`compose.nix`) that drives the full endpoint set over a
hand-assembled host — six test suites, no `nixosSystem` in any of them. Real configurations
enter one directory later, `tests/`: four hosts spanning the dimensions, the real
extraction and extendModules step, an eval-only gate forcing every endpoint of every host to a
`.drv`, and e2e boots of the assembled artifacts under OVMF/KVM.

## Why blocks

**A block tests every variant of its mechanism, so the mechanism is not what breaks.** A host can
still be broken — it can declare parameters, or a combination of them, that do not go together —
but that is one host failing (during tests or deploying) on its own configuration while the world
keeps working. Today it is the other way round: hosts are green and the world is broken, because
what gets tested is a host's toplevel and not the machinery that has to deliver it.

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
  host's storage declaration for root.
- **L2 (amended, aoj) — a ZFS pool is a kernel object: the install creates it, or the format-VM
  does at build — never userspace assembly.** A pool has its own GUID, hostid and feature flags;
  it cannot come out of `mke2fs -d`-style assembly. But there is a kernel that can make one: the
  format-VM runs disko over the host's OWN disko layout in a VM on the RUNNER's architecture (the
  layout is data, so its scripts are generated against runner pkgs — an aarch64 image formats on
  an x86 box with no binfmt), sets the target's hostid before `zpool create` so first boot imports
  without `-f`, and injects the closure without executing one target-arch binary. So `#image-raw`
  / `#image-qcow2` for an unencrypted zfs host WITH a disko layout are real endpoints; a zfs host
  with no layout keeps the hole (a named artifact that fails to build), and the encrypted pool is L3's.
- **L3 — encryption is a property of the storage layout, and the encrypted pool is install-only.**
  No `#image-*` is ever encrypted. Correctness, not tidiness: a pool created with a store-visible
  placeholder passphrase is compromised for its whole life — `zfs change-key` rewrites neither the
  master key nor the previous wrapped key on disk (measured). The format-VM makes UNENCRYPTED
  pools (L2); an encrypted zfs host's runtime disk images stay holes the composer names, and its
  pool is created at install time with the real passphrase (delivered through the slot, read by
  disko's create off the published install-slot path).

Derived:

- **L4 — `format = kexec | ipxe` ⇒ `runtime.mode = memory`.** Same reason as L1: no disk.
- **L5 — `personalize` requires a writable slot in the finished artifact.** Which formats have
  one is measured, not assumed — see the slot's table.
- **L6 — a squashfs store is written by the image, never by an install.** The mirror of L2:
  `nixos-install` populates a filesystem, and a squashfs is generated from one. The deliverable
  for a `runtime.storage = squashfs` host is the runtime image itself, and its `-install`
  endpoints are holes the matrix names.
- **L7 — an install's target is WHOLE disks, never a partition inside one (DECIDED, aoj
  2026-09-16).** The act's two promises are disk-granular — an install clears exactly the
  declared disks, and never touches one it was not given — and a target sharing a disk with
  anything foreign would make both impossible to state. Installing into an existing
  partition is out of scope: a refused declaration, not a smaller install.

## The endpoint set — DECIDED

One prefix, the same set for every host; a host does not choose which endpoints it gets.

    runtime images   #image-iso   #image-raw   #image-qcow2   #image-kexec   #image-ipxe
    install images   the same five with -install, and for the disk formats the
                     memory-rooted wrapper: #image-raw-install-inmemory
                     #image-qcow2-install-inmemory
    sidecars         #image-secrets-iso   #image-secrets-vfat   #image-secrets-json
    phase 2          #image-personalize
    store artifacts  #closure   #derivation             (the host as it runs)
                     #closure-live   #derivation-live   (the memory-rooted variant)

A sidecar is named by how the consumer takes it: a filesystem it mounts (`iso`, `vfat`) or a
format it reads (`json`) — there is no partition table and nothing boots. `image` means "an
artifact you get as a file", not "something that boots", `json` is a full member of the set.

`#closure` / `#derivation` are keyed on the VARIANT, not the format: `#image-raw` and
`#image-qcow2` of one host hold the same closure, while `#image-iso` holds a different one
because L1 changes the configuration. A host having several toplevels is visible in a name
instead of hidden in a flag.

**Every host exposes the whole set, and every endpoint is under test** — an endpoint that exists
only for the host that needs it is an endpoint nobody notices breaking.

**A law-forbidden combination is a hole, and a hole fails at BUILD, not at eval.** The endpoint
is present like any other; its `.file` is a real derivation that fails to build, printing which
law and what to use instead. It is never an eval-time throw: a throw would crash `nix flake show`
and make the name vanish, exactly the per-host divergence this repo exists to kill. So the set
stays whole and identical for every host, `nix flake show` lists all of it, and building a
forbidden pair is the only thing that fails — loudly, with its law. A host's flake exposes the
set uniformly (`builder.lib.deliverables` splits it by KIND — images to `packages`, runners to
`apps` — never by whether a pair is allowed); nothing is hand-listed or filtered per host. Each
hole is a `hole-<host>-<endpoint>` target the suite BUILDS and asserts fails with its law —
`builtins.tryEval` sees eval throws, never build failures, so the proof has to be a real build.

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

A disk-rooted host with a disko layout — ext4 and zfs alike — is formatted by the format-VM (a
RUNNER-arch VM, never emulation), so one declaration shapes the runtime fileSystems, the image
and the install. Assembly remains the backend for everything userspace can generate whole: the
squashfs formats, the wrapper images (an installer's disk is its own, not the host's), and a
layout-less ext4. No target-arch code executes on any image path.

| host runtime | `#image-iso` | `#image-raw` / `-qcow2` | `#image-kexec` / `-ipxe` | `#image-*-install` |
|---|---|---|---|---|
| memory / squashfs | yes | yes | yes | **unsupported (L6)** — deploy `#image-*` itself |
| disk / ext4 | yes (L1) | yes | yes (L4) | yes |
| disk / zfs | yes (L1) | yes — format-VM (unencrypted + layout; encrypted is **L3**, no-layout refuses) | yes (L4) | yes |

Every hole is a law, not a per-host switch, and a failed build, not a crash: it is
a property of `runtime.storage` (and, for the zfs runtime images, of `install.encrypted`), reads
the same for every host that has one, and
names its own replacement.

## The blocks

| block | in | out |
|---|---|---|
| `image` | a system, a format | the artifact, and the toplevel that went into it |
| `install` | a closure and how to place it | a system that installs it |
| `secrets` | files, a sidecar format | a sidecar runner |
| `personalize` | a finished artifact, files | that artifact with its slot filled |

`#closure` / `#derivation` / `#closure-live` / `#derivation-live` are **not blocks**. They are
names for something a block already returned; naming them costs nothing and building them twice
is what produces a reconstruction that has to be asserted equal to the original.

What the endpoints map to:

| endpoint | is |
|---|---|
| `#image-<format>` | `image(host, format)` |
| `#image-<format>-install` | `image(install(host), format)` |
| `#image-<format>-install-inmemory` | the same, with the wrapper memory-rooted (disk formats only) |
| `#image-secrets-<format>` | `secrets(…, sidecarFormat)` |
| `#image-personalize` | `personalize(artifact, slot, files)` |
| `#closure` / `#derivation` | the host's toplevel, named |
| `#closure-live` / `#derivation-live` | the toplevel `image` returned for a live format |

## The composer

Whoever calls the blocks — `lib/` — is the composer: the one place that knows the host. Blocks do
not know about each other, do not call each other, and never see a host.

**A block's input is derivations and strings, never a configuration.** The boundary is not
policed but made unrepresentable: the composer extracts what a block needs — toplevel, kernel,
initrd, kernelParams, espBinary, rootMode, closure, names — and the block is handed nothing a
host option could be read from. The positive proof is the block's own tests, driven from a
record assembled by hand with no `nixosSystem` in it. Two of those values deserve their own
sentence: **espBinary comes from the TARGET's systemd**, because the blocks' tools are the
runner's and a runner-arch `pkgs.systemd` carries no aa64 binary at all — this is what keeps the
arm builder out of the image path; and **rootMode is derived, not declared** — a tmpfs root is
what memory-rooted means.

Three consequences, derived in the plan and kept:

- **Format is the first decision, not the last.** A live format packs the memory-rooted variant,
  and the variant is a configuration change — so the composer evaluates it before anything enters
  a block, and the extraction sits between the evaluated system and `image`. The pipe's carrier
  changes shape exactly once, at that extraction, and the extraction is written explicitly rather
  than smuggled into a block. The iso variant additionally carries the MEDIUM's runtime face —
  mount the iso9660 by label, loop-mount the squashfs store out of it — and the label is the one
  constant spanning eval and artifact: both sides derive it from the same name through the same
  `ids` tool, and the e2e boot is what tests the agreement.
- **The store shape enters from above** (DECIDED). `kexec` / `ipxe` need the store in the initrd
  — there is no disk; `raw` / `qcow2` need a partition — an EFI stub refuses a 1.3 GiB initrd
  (`EFI_OUT_OF_RESOURCES`, measured). The composer picks the shape because it knows which format
  it is asking for, and **`image` validates that the shape it was handed is legal for the format
  it was asked for** — a wrong composition fails at eval, in `image`, instead of at boot on the
  machine. On the `-install` half the shape is the **wrapper's own** (its store carries the
  installer and the host's closure); the target's storage never shapes it, and the wrapper's
  disk takes no layout, so it stays on assembly. The runtime disk half of a zfs host is the
  format-VM's (L2 amended): real for an unencrypted host with a layout, and a hole the composer
  names at eval only for the encrypted one (L3) or one that declared no layout.
- **The root mode travels with the payload and `image` validates it the same way**: `iso` /
  `kexec` / `ipxe` cannot boot a disk-rooted system, so `(format ⇒ rootMode)` fails at eval like
  a wrong store shape. `install` takes `rootMode` too, and a variant that does not exist refuses
  BY NAME, exactly like L2 — a missing variant is a red eval, never a green name.

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
mechanism), `gptDisk` (partition images → GPT disk, layout emitted as JSON), `store` (below),
the read-only-store mechanism and the two runtime faces built on it (`roStore`, `netbootFace`,
`isoFace`), `slotFace` (where a slot lives per format), and the install actions
(`actionInstall`, `actionWipe`), both keyed by the target storage so zfs rides only where the
target is zfs. The e2e recorder is deliberately NOT here: it is a harness helper no block
receives, and it lives with the tests — the install block's `report` input is the seam it
plugs into.

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

A FAT label is too short to carry a hash, so for labels the rule inverts: **a label is either a
lookup handle or it is nothing, and only one artifact in an attachment set may own a given
handle.** The sidecar's `SECRETS` is a handle — its consumer mounts by it; the slot's label is
deliberately none (`SLOT`), because a slot is found by partlabel or offset and a second `SECRETS`
would race the real one.

**A generated handle is HANDED BACK, never left for the consumer to re-derive.** The iso medium's
volume id and the iso sidecar's are name-derived hashes, not constants, so a consumer cannot guess
them — the `secrets` block returns `label`/`volumeId`, and `image`'s iso output returns the
medium's `label`, both the exact string the artifact was stamped with (`test-sidecar-identity`
reads it back off the built medium with `blkid` and asserts the agreement). The one handle a
consumer may hardcode is the vfat sidecar's `SECRETS`, because it IS a constant; everything else
comes off the endpoint.

**Both properties are per-architecture.** A native and an emulated build of one squashfs come out
the same size and not the same bytes, so "the same bytes" holds for two builds on the same
architecture and is not a claim about an artifact built in two places. That matters for the
aarch64 hosts, whose images are built emulated or on a foreign builder.

**The format-VM's outputs carry identity but not same-bytes.** A pool made in the VM generates
its own vdev GUID, stamps birth-TXG times, and lays blocks down as the kernel schedules the
writes (txg sync, writeback) — none of which has a seed. Every stamp the tools DO expose is
pinned (a fixed VM rtc, `SOURCE_DATE_EPOCH` into every mkfs, `zpool reguid -g` to a name-derived
guid, the nix db normalised), so two builds give the same CONTENT; same-bytes is the assembly
path's alone. This is the price of L2's amendment, taken knowingly (aoj): a kernel-made
filesystem beats a byte-stable one that cannot exist.

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

How the formats are made, as built: `raw` / `qcow2` are the format-VM whenever the caller hands
over a disko layout (a HOST's disk endpoints; zfs requires it, ext4 uses it when present) —
disko formats a blank disk from that layout inside a runner-arch VM and the closure/db/profile/
ESP content is injected as data, no target-arch code. Without a layout they are the GPT assembly
— ESP, store partition, optional slot partition — which is what every installer wrapper stays on,
and what a zfs shape refuses. `qcow2` is the same disk in a different envelope either way. `iso` puts the kernel,
initrd and loader entries INSIDE the ESP image, points an El Torito record at it, and marks the
same image in a GPT so the file also boots dd'd to a stick (the nixpkgs pattern); the iso9660
itself carries the squashfs store and the slot file. `kexec` / `ipxe` are one tree — kernel, the
caller's initrd with the squashfs store appended as a cpio segment at the nixpkgs name
(`/nix-store.squashfs` — DECIDED: compressed and lazily read), and both loader descriptors.

For the disk formats the composer additionally states WHERE the store rides
(`storePlacement`): in its own partition — the disk stays the store medium — or inside the
initrd on the ESP, the netboot payload behind a bootloader, in which case the disk carries
nothing but the ESP and the slot partition and the booted system holds no claim on the medium
it started from. An initrd-carried store is squashfs and memory-rooted by validation; the
other formats fix their own placement and refuse to be told one.

## install

Wraps a host in an OS that unpacks it. Its output is a system, so it sits **before** `image`,
and the `-install` half of the endpoint set is `image(install(host), format)`
— the format does not know it is packing an installer.

**An install is how a system GETS onto a machine, and nothing more (DECIDED, aoj
2026-09-18).** It is a wrapper around an image: what reaches the target is the same artifact
the image endpoints produce, and the format only decides how the machine is reached — a
stick, an iso, a netboot, a kexec into a running kernel. It is also a takeover: the machine
it lands on may have been running anything, or nothing this world knows about.

**What is delivered comes in two shapes, and a host's own declaration picks one.** An
`image` is a finished disk written as it is — what it holds is never inspected, so the same
act delivers another operating system as well as a NixOS host, and what boots is bit for bit
what was tested. A `script` is a recipe that creates the target's storage, and the host's
closure installed into it. A host that declares a disk layout gets `script` and the layout's
own script runs; a host that declares none gets `image`.

**The layout is disko's, and blocks never reads it (DECIDED, aoj 2026-09-19).** A host that
describes its disk describes it once, in disko, and the install runs disko's own script to
create and mount it — no translation, no second opinion about what those partitions mean. A
host that wants a disk but has nothing to say about it takes a template, which it imports
into its own configuration and can override: then it too has a layout, and there is no
special case. What blocks still owns is the part disko has no answer for without a virtual
machine: building the disk as a FILE.

**Its input is a closure, not a system**. Measured against what the current
installer actually consumes — a disk-preparation step, a mount step, the toplevel, the pool name,
and where the key lands — that is five extracted values rather than a configuration. The
difference is not in what the block can do; it is that a closure can be tested without a host and
a configuration cannot. The block is deliberately asymmetric: derivations and strings in, a system
out.

Two things are in flight and they are different: the system being installed, and the system doing
the installing. The block builds the second and carries the first. **What gets installed is always
the host as it runs**: a live format on an `-install` endpoint shapes only the wrapper's
packaging, never which closure is carried.

Two SLOTS are in flight too, with different lifetimes: the installer's OWN slot — what it
reads while it runs, `image`'s input when the installer is packed — and the target's, which
the act fills with those same files once the storage exists. Same name, same contents, two
moments.

**The install ACT.** Its contract: an install the
machine cannot carry out is refused before anything destructive, and a refused target is left
untouched — refusal is a fact of the machine (an absent disk, a disk carrying the running
system, a capacity the carried closure cannot fit, an encrypted target whose passphrase was
never delivered), never of eval. **An install REPLACES what is on the declared disks, every
time.** The blast radius is the same two bounds as ever: only the disks the host declares,
and never a disk the running system lives on. The closure installs offline, and the teardown
releases the target completely, so the installed system comes up on its own. An encrypted
target's boot-time pool key is delivered the same way every other secret is — into the slot
the target's layout provides; nothing is generated on the target and nothing rides the
store. Reading it from there before the pool unlocks is the host layout's business, not the
act's.

How the machine leaves the install is a choice, and one option is not like the others:
handing straight over to what was just delivered is what a stick left in the machine cannot
turn into a reinstall loop — firmware never looks at it again, so the next thing that runs
is the installed system rather than the installer a second time. Going through firmware, or
stopping and waiting for someone to pull that stick, stay available for machines that need
them.

The block's installer OS is a minimal system of the block's own whose one service runs the
action against the block's inputs: the install script, when a host states one, creates the
target's storage and mounts it, `disks` names what the act clears, `storage` selects the
zfs-specific teardown — and is the only thing that puts zfs into the installer, kernel module and userland
both; an ext4 installer carries neither. `report`, when set, is an executable the installer
calls with one line per milestone; unset, the installer reports nothing. The installer ROOTS
per wrapper: its own disk partition for raw/qcow2, the netboot face for kexec/ipxe, the iso
face keyed by the medium's label for iso — the same faces the live variants wear. Its
hardware support is the HOST's declaration, handed as the extracted `machine` record —
kernel, module sets, firmware — so the installer boots exactly where the host boots and
carries nothing the host did not claim to need; a host unsure of its machine declares the
broad driver set in its own configuration and its installer inherits it through the same
values. A systemd watchdog resets a wedged install on a console-less box instead of letting
it hang forever. The installer's slot feeds the
delivered-key convention (`/run/sops.age`, and `/tmp/zfs_root_key` for a pool passphrase
riding the same slot), whichever face delivered it — so phase 2 on an `-install` artifact is
the same personalize as everywhere else.

Where a host has a disko layout, that layout IS its install script — the same declaration
formats the target that boots it, and no partitioning is written twice. The invariant that
survives every shape: the blast radius is exactly the disks the host declared, the named
devices and nothing beside them.

**A disk wrapper roots two ways, and both are endpoints, because the choice is the
operation's.** `#image-raw-install` / `#image-qcow2-install` are disk-rooted: the medium
carries the closure on its own partition, RAM-independently — for installing a DIFFERENT disk
from a medium that persists (a usb stick into a physical server). `#image-raw-install-inmemory`
/ `#image-qcow2-install-inmemory` are memory-rooted: the closure rides the initrd on the ESP
and the booted installer holds no claim on any disk — the target is whatever the host's
layout names, an arbitrary disk, and the boot medium itself is NOT excluded. That last
freedom is what the one-disk machine needs (a cloud VM that cannot attach a second boot
disk), but it is a consequence, not the definition. The name marks the in-memory variant
because for raw/qcow2 both wrappers ARE disks, so "disk" would distinguish nothing. Which endpoint an operation consumes is the host's call
carried by deploy: the host declares what its machine can take, deploy reads the host and
picks the endpoint — blocks always offer both, and neither is derivable here (the deciding
facts, closure size against the machine's RAM and whether the medium is the main disk, are
not eval facts). The installer's root mode is the WRAPPER's property, never the host's
`runtime.mode`, which shapes only the system being installed.

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
| squashfs in the initrd (netboot) | the same read-only image, ridden as an appended cpio segment and loop-mounted by the netboot FACE (`tools/netboot-face.nix`) — one module carrying the mounts, the registration, and the initrd-slot hand-over |

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

Status: the gap is closed on the blocks path — `tests/hosts/modules/` carries both
halves for every shape that boots: `read-only-store.nix` (the squashfs partition mount and its
registration, the appliance case), `live-iso.nix` (the medium by label, the loop-mounted store,
the same registration), and the netboot registration rides the live module. What remains is
carrying these into the repo's module tree at integration.

## secrets

Files in, a sidecar out. Nothing boots and there is no partition table.

**The slot is a folder for the host's secrets, and blocks never learns what they are (DECIDED,
aoj 2026-09-18).** What a host puts there, what it calls those files, what format they are in
and what they are for is the host's implementation — an age identity, a sops bundle, a pool
passphrase are all the same thing here: bytes with a name. Blocks carries them to the declared
place, at the declared mode, and opens none of them. Anything that would require reading one —
validating a key against a bundle, deciding which file unlocks a pool — belongs to the host,
which is the only side that knows what it wrote.

A sidecar is data placed beside an image or file for the consumer to take. **Whether the consumer
mounts it or reads it is a property of the sidecar FORMAT, not part of what a sidecar is**. The
word "medium" does not appear in the blocks: it already means something else in this repo
(`realization.root.medium`), and one word may not carry two meanings.

**Its output is a runner, not a derivation** — the same argument personalize carries: a secret
in a derivation is a secret in the store, and a sidecar exists to carry secrets. Phase-one
mechanics are shared through the `fat-image` tool's app, so a sidecar and a slot are still one
mechanism. A declared file says WHERE its bytes come from, and that is the only question asked
about it: declared in nix (so already in the store — for material that is already encrypted),
read from the environment when the runner runs, or read from a path then. The last two never
touch the store, and the environment form is what a deploy running straight from a flake has: no
file on disk anywhere.

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

For an `-install` image the slot is consumed twice: the install reads it while it runs — that is
how a host's own storage step gets at whatever it needs, from a place blocks publishes and the
host reads — and then fills the slot the target's layout provides, so the installed system finds
its secrets exactly where it would have, had the image written them. That is why L2 costs
nothing: the installer's own slot is a plain, writable, well-known place, and the pool is created
on the target with the real passphrase — no placeholder key in a cacheable derivation.

**Install-time secrets ride the same delivery set (DECIDED, aoj 2026-09-15).** The bricks
combine like everything else: the pool passphrase may be `embedded` in the installer's slot
without complication, or arrive `deploy`-time (colmena-shaped push). A console prompt is NOT in
the set and will not be implemented — the goal is full automation, and a host that wants an
interactive unlock changes its zfs layout, not the delivery.

**The safe combination is the HOST's and DEPLOY's responsibility, never blocks'** (DECIDED).
Blocks do every step safely and guarantee one thing: no secret ever remains anywhere except the
output artifact — no store path, no leftover temp state. Whether an embedded key on an install
medium is protection enough is a per-host call: it already achieves "no plaintext data at rest"
(the image installs over itself and is overwritten on first boot), and a host needing more
reaches for deploy-time delivery, hardware encryption, or an HSM — outside blocks either way.

**Where the secrets come from**: openbao. The deploy script obtains them through its host role
at deploy time and hands them to the runners as OUTSIDE input — which is exactly why `secrets`
and `personalize` take their secrets as declarations resolved at run time, never as derivations.

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
3. **every declared file has bytes to place** — a source that resolves to nothing is a named
   refusal before the first write, never a file quietly left out;
4. **read back what landed** — out of the filled slot, before it is placed.

**Where the filled artifact lands is the caller's, via a second argument.** Omitted, the runner
patches the input in place (the default, and what an e2e boots). Given a path, or `-` for stdout,
it leaves the input untouched and emits a filled artifact instead: the bytes before the slot, the
filled slot, the bytes after — the slot's window substituted in a stream, byte-precise, never
rebuilding the image. Only slot-sized bytes of secret ever exist, in a tmpfs the size of the slot,
never the image. This is what lets a build server fill a slot and send the result straight to a
hypervisor without the secret-bearing artifact ever touching the build host's disk — offset and
size still read out of the artifact, so a wrong offset is refused, not silently written. The
convention is one arg on the runner, identical whether it is a flake app or `getExe`'d in a deploy.

## The slot

A slot has two faces — a place in the artifact, and a place the running system sees — and no
single block owns both. `image` cannot own it outright: it does not know a host's storage
topology and must not reach into it.

What the faces ARE is fixed by the format:

| format | artifact face — where a tool writes | runtime face — how the booted system reads it |
|---|---|---|
| iso | a file at a path inside the iso9660 | loop mount of `${sysroot}/iso/<path>`, `neededForBoot` |
| raw / qcow2 | a GPT partition, found by NAME | mount of `/dev/disk/by-partlabel/<name>` |
| kexec / ipxe | an appended cpio segment in the initrd — RESERVED by the build as a marker segment, so phase 2 can refuse a tree that never declared one | stage 1 hands the appended files over at `/run/initrd-slot` |

For `iso` the slot is a file and not the isohybrid partition, because that partition is not a
handle: a SATA cdrom exposes no partitions at all, virtio does, and a second disk shifts the
names (measured, in the plan). The offset is read out of the finished image
(`xorriso … report_lba`), never bookkept at build time.

An install adds a third face, and it is the same slot: the target's disk does not exist at build
time, so what the image would have written is written during the install instead, into the slot
the target's own layout provides. The host therefore reads its slot the same way whichever
produced it — one declaration, one name, two ways of arriving. What the install itself must
refuse follows from this: an installer whose slot never received the files the host declared
stops before anything destructive, rather than clearing a disk and discovering the lack
afterwards.

The two faces enter the pipe at different points: the **runtime face** is a payload
transformation — it adds a mount to the system, so it happens before `image`, exactly like
`install`; the **artifact face** is `image`'s input — "reserve a partition named X of size Y",
"place a file at path Z" — and nothing more. `neededForBoot` on the runtime mount is
load-bearing, not an optimisation: `sops.useSystemdActivation` is false on c, ax and iris, so
sops-nix decrypts during activation, when the only filesystems are the ones stage 1 mounted.

**The rule: the slot's name is the host's declaration (`slotName`), and there is no default** —
a mistyped declaration must fail eval, never silently land on a fallback. Where an fs layout
owns the disk, the same declaration names the layout's slot partition — one binding, read by
both the layout and the composer; the ext4 layout does exactly this, a vfat slot partition
disko formats beside the root. Where there is no layout — `iso` has no layout, `kexec` /
`ipxe` have no filesystem at all — `image` makes the slot in the shape it is already making. An
unencrypted zfs host with a disko layout now HAS an `#image-raw` (the format-VM makes it), and
its slot is the layout's own partition — the same binding the ext4 layout uses. Only the
encrypted zfs host still has no runtime disk image to put a slot in (L3), so that combination
stays the hole the matrix names.

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

## The schema seam

`docs/blocks/tests/schema.nix` is the one-direction mapping from the repo's typed host schema
onto the dimensions: `root.medium` splits into `runtime.mode` + `runtime.storage`,
`secretsTransport.kind` names exactly one `secrets.delivery` member (sops-boot → deploy,
creds-cd → sidecar, baked-partition → embedded), `delivery.modes` survives as the list of
endpoints the host's operations consume, and `pool`/`encryption` ride to the install per L2/L3.
A pair of old values that does not go together — `boot=ram` with a disk medium, an unknown
mode — is REFUSED at eval, never guessed around. `profileModules { live }` appears nowhere: it
is a call-site argument, not host data, and it dies with the old image path. The seam's test
runs the design's replacement table as code, against fixtures AND a live host.nix sample.

## What integration deletes

The blocks path uses no nixos-generators and no iso-image module anywhere — `#image-iso` is the
block's own xorriso assembly and `live-iso.nix` is its runtime face. At integration the
`nixos-generators` flake input therefore dies together with its three consumers —
`lib/40_build/image/installerIso.nix`, `lib/40_build/image/guestIso.nix`, and the
`mkHost/images.nix` wiring — and the deprecation warning with them. Until then the old path
stays untouched; killing the warning early would mean changing the code that is about to be
deleted.

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
  and a marker unit records what only a running system can prove onto the result disk the
  harness attaches — that
  userspace came up, and what the slot really holds (empty on a pristine image, the planted
  key's own public half after personalize). The test hosts are throwaway configurations that
  exist for the matrix, not production hosts wearing a second hat.
- **`apps` must be forced at eval.** Both breakages the withdrawn branch shipped lived in `apps`,
  which neither `#drv-diff` (toplevel only) nor the check suite (checks only) evaluates. The
  check is eval-only — it discards the string context, asking what the names are without asking
  for the things to be made.
- **Forcing a name is never read as "works": the coverage TABLE says which is which.** Every
  (host, endpoint) pair carries exactly one declared status — `booted`, `hole`, `eval-only` —
  and the suite fails when the table is incomplete against the endpoint set, when
  a declared hole's `hole-*` target does not fail to build with its law, or when the holes drift
  from the laws. "It only evaluates" is
  a visible name someone wrote down, never a default the suite hands out. Every `booted` must be
  claimed by an e2e's own witness declaration, asserted as set equality — the table cannot drift
  from what the suite proves in either direction.
- **The eval gate is one host per attribute, and the gates run as separate processes** — the
  whole set in one evaluation does not fit a small machine, and a check that is green only where
  there is enough RAM is not a check.
- **The suite has one entry point, and its target list is discovered, never maintained by
  hand** — a test that exists but nothing runs is not a gate.

## Open

1. A third validation gate, `#verify`-shaped: take a FINISHED artifact plus the host's
   declaration and check they correspond — format, slot present and formatted, closure carried —
   independently of the build path that produced it. The two existing checks each catch one
   failure (eval: nothing composed a slot; personalize: the artifact drifted from its
   declaration), but neither validates an artifact someone hands you. Whether this gate is
   wanted at all, and whether it sits in deploy or as its own app, is aoj's call.
2. What belongs in `tools` besides the current set — a placeholder so additions stay conscious.
3. The schema seam is data-only so far: `requires.secrets` → the files/keyTarget record, and
   driving the composer's host records through the seam, remain for integration. Further
   changes are expected here (aoj), too early to describe.
4. arm artifacts on an x86 box. The image PATH no longer needs the target arch — the format-VM
   runs runner-native and injects the closure as data, proven by eval (an arm `#image-raw`'s
   derivation is `system = x86_64-linux` while its packed toplevel is aarch64). What remains is
   BUILDING the aarch64 closure: the kernel and glibc substitute from cache, but the per-config
   derivations (systemd units, `/etc/*`) carry `system = aarch64-linux` and nix refuses them on
   x86 — so this still needs `boot.binfmt.emulatedSystems` (build via qemu-user, not full-system
   emulation) or a dedicated native aarch64 builder. Parked on that capacity, not on feasibility.
5. Integration into the repo: delete lib/50_install (now `action-install` in blocks), retire
   nixos-generators and the old image paths, and drive real host records through the schema
   seam. This is the last track and the one the withdrawn branch got wrong by leaving deletions
   for last — each move pairs with its deletion.
