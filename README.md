# Blocks

An image / install / secrets factory for NixOS hosts. Four `evalModules` blocks (image,
install, secrets, personalize) that never see a host, and one composer that does: hand it
an extracted host record and it returns the full endpoint set — runtime images (iso, raw,
qcow2, kexec, ipxe), installer images including the memory-rooted variants, secrets
sidecars, and phase-2 personalization runners.

The design — vocabulary, laws, endpoint set, contracts — is
[`blocks-design.md`](blocks-design.md).

## Use

As a flake input:

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
      inherit (builder.lib.mk { inherit pkgs; }) compose;
      endpoints = compose myHost;   # myHost: the extracted host record, see below
    in
    {
      packages.${system} = {
        image = endpoints.image-raw.file;                    # bootable GPT disk image
        installer = endpoints.image-kexec-install.file;      # netboot tree that installs the host
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

Every host gets the same endpoint set; combinations a law forbids are named holes that
refuse at eval (a zfs host's `image-raw`, a squashfs host's installers), never endpoints
that quietly mean something else.

The host record is extracted DATA — derivations and strings, never a NixOS
configuration. [`examples/`](examples/) holds one reference host per dimension — plain
ext4, zfs installers, encrypted zfs (pool key delivery and unattended unlock), a
squashfs appliance — plus a copy-paste consumer flake; the suite gates them, so they
cannot drift. The extraction itself is `lib.extract`
([`tests/extract.nix`](tests/extract.nix)), and [`tests/hosts/`](tests/hosts/) holds the
records the e2e prove.

## Tests

    ./run-all.sh              # everything: contract tests, per-host eval gates, e2e
    ./run-all.sh --list       # list the discovered targets
    ./run-all.sh e2e-install  # substring filter

The target list is discovered, never maintained by hand. The e2e boot real artifacts
under OVMF/KVM and need `kvm`, and a cold full run builds ~20 GB into the nix store.
`nix flake check` runs only the cheap, host-free mechanism contracts; CI runs those on
every push and the full suite on `main`.
