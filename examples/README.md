# Examples

Reference usage, one file per kind of host. Each `host-*.nix` is a complete host record
built from a real `nixosSystem` and composed into the full endpoint set; the suite gates
them (`test-example-*` via `../run-all.sh`), so they cannot drift from the code.

| example | dimension it shows | deliverables shown |
|---|---|---|
| [`host-ext4.nix`](host-ext4.nix) | plain disk VM, disko layout owns disk + slot | raw, qcow2, live iso, sidecars, personalize |
| [`host-zfs.nix`](host-zfs.nix) | zfs server — the pool is created at install (L2) | the three installers: kexec deploy, USB stick, memory-rooted `-inmemory` |
| [`host-zfs-encrypted.nix`](host-zfs-encrypted.nix) | encrypted pool (L3): passphrase at create, boot key delivery, unattended unlock | kexec installer + personalize |
| [`host-memory.nix`](host-memory.nix) | squashfs appliance — the runtime image is the deliverable (L6) | raw appliance image, netboot |
| [`flake-consumer/`](flake-consumer/) | downstream flake pulling the builder from GitHub | packages + personalize/sidecar apps |

Build any shown endpoint directly:

    nix build -f examples example-ext4.endpoints.image-raw.file
    nix build -f examples example-zfs.endpoints.image-kexec-install.file

`flake-consumer/` points at the GitHub url, so it is the one piece the suite does not
evaluate — it is the copy-paste starting point for your own repository.
