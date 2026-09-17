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
        secrets = {
          delivery = [ "embedded" ];
          bundle = "/run/secrets/srv/bundle.yaml";
          keyTarget = "/sops.age";
          files = [{
            target = "/sops.age";
            source = "/run/secrets/srv/host.key";
            runtimeSource = "/run/secrets/srv/host.key";
          }];
        };
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

The storage, the machine, the live variants, the install recipe and the disk list are
read out of the configuration. What you state is what a configuration cannot know: the
slot's name, and where the secrets will be when phase 2 runs.

Every host gets the same endpoint set; combinations a law forbids are named holes that
refuse at eval (a zfs host's `image-raw`, a squashfs host's installers), never endpoints
that quietly mean something else.

The API:

- `lib.imagesFor { pkgs; host; slotName; secrets ? …; install ? …; }` — the front door.
- `lib.recordFor` — the same, stopping at the record, for a consumer who wants to adjust
  a field before composing it.
- `lib.mk { pkgs }` → `tools`, `compose`, `modules` (`liveNetboot`, `liveIso label`,
  `readOnlyStore { device }` — the host-side modules a memory-rooted host needs),
  plus `imagesFor` and `recordFor` bound to that `pkgs`.
- `lib.hostRecord` — the record's option interface: every field, its type, and what reads
  it. `compose` validates through it, so nothing is implicit.

[`examples/`](examples/) has one host per dimension — ext4, zfs installers, encrypted zfs
with unattended unlock, squashfs appliance — each gated by the suite, so the reference
cannot drift from the code. [`tests/hosts/`](tests/hosts/) holds the records the e2e
boot.

## Tests

    ./run-all.sh              # everything: contract tests, per-host eval gates, e2e
    ./run-all.sh --list       # list the discovered targets
    ./run-all.sh e2e-install  # substring filter

The target list is discovered, never maintained by hand. The e2e boot real artifacts
under OVMF/KVM and need `kvm`, and a cold full run builds ~20 GB into the nix store.
`nix flake check` runs only the cheap, host-free mechanism contracts; CI runs those on
every push and the full suite on `main`.
