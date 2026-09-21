# Blocks

An image / install / secrets factory for NixOS hosts. Four `evalModules` blocks (image,
install, secrets, personalize) that never see a host, and one composer that does: hand it
an extracted host record and it returns the full endpoint set — runtime images (iso, raw,
qcow2, kexec, ipxe), installer images including the memory-rooted variants, secrets
sidecars, and phase-2 personalization runners.

The design — vocabulary, laws, endpoint set, contracts — is
[`blocks-design.md`](blocks-design.md).

## Use

Start from a ready host: every directory under [`examples/`](examples/) is self-contained
and copy-pasteable.

    cp -r examples/ext4 ~/my-host && cd ~/my-host
    $EDITOR host.nix          # your configuration, your disk id, your secret paths
    nix build                 # the image
    nix run .#personalize -- ./result   # phase 2 fills the slot

Or wire it into your own flake — one evaluated NixOS system in, every endpoint out:

```nix
{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/*.tar.gz";
    builder.url = "github:AoJ/nix-builder";
    # Optional: run it on YOUR nixpkgs instead of the pinned one. The suite's green is a
    # statement about the pin — at an overridden revision the proof is your own run.
    # builder.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, builder }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      endpoints = builder.lib.imagesFor {
        inherit pkgs;
        host = self.nixosConfigurations.srv;   # your own evaluated system
        slotName = "secrets";
        # What goes in the slot, and where each file's bytes come from. `text` is declared
        # in nix (so: already-encrypted material), `env` is read when the phase-2 runner
        # RUNS, `file` is a path it reads then. The builder carries the bytes to the name
        # you chose and never opens them.
        secrets.files = [
          { target = "/sops.json"; content.text = mySecretsBundle; }
          { target = "/pool.pass"; mode = "0400"; content.env = "SRV_POOL_PASS"; }
        ];
      };
    in
    {
      packages.${system} = {
        image = endpoints.image-raw.file;                 # bootable GPT disk image
        installer = endpoints.image-kexec-install.file;   # netboot tree that installs the host
        qcow = endpoints.image-qcow2.file;
      };

      # Phase 2 runs OUTSIDE the store on purpose (a secret in a derivation is a secret
      # in the store): the runner takes a finished artifact and fills its slot.
      apps.${system}.personalize = {
        type = "app";
        program = nixpkgs.lib.getExe endpoints.image-personalize.run;
      };
    };
}
```

The storage, the machine, the live variants, the disk list and — where the host has a disko
layout — the install script are read out of the configuration. What you state is what a
configuration cannot know: the slot's name, and what belongs in it.

**An `-install` artifact is how that system gets onto a machine, and it is a takeover.** It
replaces what is on the disks the host declared, every time, and touches no other disk;
installing onto storage that already holds a system would leave a machine that is half one
system and half another. What it delivers comes in two shapes: a host that describes
its disk in **disko** is installed by disko's own script — blocks never reads that layout,
it runs it; a host that describes none gets its own **image**, written as it is, bit for
bit what was tested, and it may hold any operating system at all. A host that wants a disk
but has nothing to say about it imports the layout template and is then simply the first
case. Where the machine goes afterwards is a choice too — handing straight over to what
was installed is what a stick left in the machine cannot turn into a reinstall loop.

**The slot is a folder for the host's secrets, and nothing more.** The builder never
generates a key, never reads one, and does not know what any file in there is for — it
carries bytes to the name you chose, at the mode you asked for. A `target` is a path
inside the slot, never on the host's own filesystem; where the host mounts its slot and
what reads it is the host's business. An `-install` artifact carries the same slot and
fills the target's on the way through.

Every host gets the same endpoint set; combinations a law forbids are named holes that
refuse at eval (an **encrypted** zfs host's `image-raw`, a squashfs host's installers),
never endpoints that quietly mean something else. An unencrypted zfs host DOES get its
runtime disk images: the pool is a kernel object, so a VM on the runner's own architecture
(never emulation) makes it from the host's disko layout and the closure is injected as data
— an aarch64 image builds on an x86 box with no target-arch code.

Each disk endpoint hands back the volume identity it was stamped with, so a consumer mounts
by exactly what was written instead of guessing: `endpoints.image-secrets-iso.label` /
`.volumeId`, `endpoints.image-iso.label` (the iso9660 volume id), and the vfat sidecar's
fixed `SECRETS` label with its `.volumeId` serial.

The API:

- `lib.imagesFor { pkgs; host; slotName; secrets ? …; install ? …; }` — the front door.
- `lib.recordFor` — the same, stopping at the record, for a consumer who wants to adjust
  a field before composing it.
- `lib.diskLayout { device; slotName; espSize ? …; slotSize ? … }` — the ext4 layout
  template, imported in the host's own configuration next to disko's module: ESP, slot,
  ext4 root, every choice visible there and overridden like any other option.
- `lib.diskLayoutZfs { device; slotName; pool; espLabel; espSize ? …; slotSize ? …;
  encryption ? null; slotMount ? null }` — the zfs variant: ESP, slot, one pool with a
  legacy root. `pool` and `espLabel` are REQUIRED, no default — each must match what the
  host states elsewhere (its root dataset, its `/boot` partlabel), and a default would be a
  second hidden source of that value. Pass `encryption = { keyInstall; keyBoot; }` for an
  L3 host, and `slotMount` when the slot must be mounted at install (an encrypted host reads
  its passphrase from it).
- `lib.paths.installSlot` — where the install action lays the slot out while it runs, for a
  host's own storage scripts to read (a pool passphrase, say).
- `lib.mk { pkgs }` → `tools`, `compose`, `modules` (`liveNetboot`, `liveIso label`,
  `readOnlyStore { device ? … }` — the host-side modules a memory-rooted host needs; the
  appliance's own store partition is the default, so it need not restate it), plus
  `imagesFor` and `recordFor` bound to that `pkgs`.
- `lib.hostRecord` — the record's option interface: every field, its type, and what reads
  it. `compose` validates through it, so nothing is implicit.

[`examples/`](examples/) has one host per dimension — ext4, zfs (runtime images AND
installers, both from one disko layout), encrypted zfs with unattended unlock, squashfs
appliance — each gated by the suite, so the reference cannot drift from the code.
[`tests/hosts/`](tests/hosts/) holds the records the e2e boot.

## Combinations and required parameters

**The front door — `imagesFor { … }`:**

| argument | required? | note |
|---|---|---|
| `pkgs`, `host` | **yes** | the nixpkgs, and your evaluated NixOS system |
| `slotName` | only if the host declares secrets | a host with no secrets builds no slot and names none; declaring secrets without it is refused by name (never defaulted — it must match the layout's partition) |
| `secrets` | no (default `{ }`) | what goes in the slot |
| `install` | no (default `{ }`) | only the `-install` endpoints read it |
| `name` | no (default `networking.hostName`) | names the artifacts |

**Read from the configuration — you state normal NixOS, nothing extra:** the storage
(`fileSystems."/".fsType`), the root mode, the architecture, the machine, the live variants;
the disko layout (`cfg.disko.devices`) and, **for a zfs host**, `networking.hostId`; the
install script (disko's own, when there is a layout) and its disk list; the pool (**zfs
only** — the first component of `rpool/root`).

**The layout templates** (imported in the host's config next to disko's module):

| template | required | optional |
|---|---|---|
| `diskLayout` (ext4) | `device` | `slotName`, `espSize`, `slotSize` |
| `diskLayoutZfs` | `device`, **`pool`**, **`espLabel`** | `slotName`, `espSize`, `slotSize`, `encryption`, `slotMount`, `poolPostCreate` |

`pool` and `espLabel` are required with no default: each must equal what the host states
elsewhere (its root dataset, its `/boot` partlabel), so a default would be a second hidden
source of that value. `slotName` is optional — omit it and no slot partition is built.

**`secrets.files`** — one entry: `target` (required, a path inside the slot), `content`
(required, **exactly one** of `text` / `env` / `file`), `mode` (optional, `"0400"`). `text`
is declared in nix (so already-encrypted only); `env` reads a variable and `file` reads a
path — both when the phase-2 runner RUNS, so nothing plaintext reaches the store.

**Which endpoints a host gets, by storage:**

| host storage | `#image-raw` / `-qcow2` | `#image-iso` | `#image-kexec` / `-ipxe` | `#image-*-install` | what you must supply |
|---|---|---|---|---|---|
| ext4 (disk) | ✅ | ✅ | ✅ | ✅ | a disko layout, **or** `install.disks` + a `script` |
| zfs, unencrypted | ✅ (format-VM, **needs a layout**) | ✅ | ✅ | ✅ | `diskLayoutZfs` (with `pool` + `espLabel`) |
| zfs, encrypted | **hole (L3)** | ✅ | ✅ | ✅ | layout with `encryption` + `install.encrypted = true` |
| squashfs (tmpfs root) | ✅ | ✅ | ✅ | **hole (L6)** — the image IS the deliverable | nothing (it has no installer) |

Holes are not a silent fallback: they **refuse at eval**, named by the law. The one hard
`-install` requirement: a host with no disko layout and no `install.disks` is refused,
because an install must know which disks it may clear.

**Every disk endpoint and sidecar hands back its volume identity** — `.label` (the
`/dev/disk/by-label` handle) and `.volumeId` — so a consumer mounts by exactly what was
stamped instead of guessing.

## Tests

    ./run-all.sh              # everything: contract tests, per-host eval gates, e2e
    ./run-all.sh --list       # list the discovered targets
    ./run-all.sh e2e-install  # substring filter

The target list is discovered, never maintained by hand. The e2e boot real artifacts
under OVMF/KVM and need `kvm`, and a cold full run builds ~20 GB into the nix store.
`nix flake check` runs only the cheap, host-free mechanism contracts; CI runs those on
every push and the full suite on `main`.
