# Blocks

An image / install / secrets factory for NixOS hosts. Four `evalModules` blocks (image,
install, secrets, personalize) that never see a host, and one composer that does: hand it
an extracted host record and it returns the full endpoint set — runtime images (iso, raw,
qcow2, kexec, ipxe), installer images including memory-rooted variants, secrets sidecars,
and phase-2 personalization runners.

The design — vocabulary, laws, endpoint set, contracts — is
[`blocks-design.md`](blocks-design.md). The code keeps its implementation inside each
block; the contracts are the blocks' option interfaces.

## Tests

    ./run-all.sh              # everything: contract tests, per-host eval gates, e2e
    ./run-all.sh --list       # list the discovered targets
    ./run-all.sh e2e-install  # substring filter

The target list is discovered, never maintained by hand. The e2e boot real artifacts
under OVMF/KVM and need `kvm`, and a cold full run builds ~20 GB into the nix store.
`nix flake check` runs only the cheap mechanism contracts.

## Flake

- `lib.mk { pkgs }` → `{ tools, compose }` — the consumer API.
- `checks.x86_64-linux` — the mechanism contract tests.
- `inputs.nixpkgs` is pinned; a consumer may override it via `follows`, and its proof is
  then its own run of the suite at that revision.
