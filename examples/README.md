# Examples

One directory per kind of host, each **self-contained**: copy it into your own
repository, adapt `host.nix`, and build. They reach into the builder only through its
public API (`builder.lib.mk`, `builder.lib.extract`) — never into its source tree, which
is what separates them from the suite's own test hosts under [`../tests/`](../tests/).

| example | what it shows | `nix build` gives you |
|---|---|---|
| [`ext4/`](ext4/) | plain disk host; one disko layout owns the disk and the slot | raw / qcow2 / live iso, installer, personalize + sidecar apps |
| [`zfs/`](zfs/) | the pool is created by the install (L2) — no runtime disk image exists | three installers: kexec deploy, USB stick, memory-rooted `-inmemory` |
| [`zfs-encrypted/`](zfs-encrypted/) | encrypted pool (L3): passphrase at create, boot-key delivery, unattended unlock | installers + the phase-2 runner they need |
| [`memory/`](memory/) | squashfs appliance — the image IS the deliverable (L6), it has no installer | appliance image, netboot tree, iso |

Use one:

    cp -r examples/ext4 ~/my-host && cd ~/my-host
    $EDITOR host.nix          # your configuration, your disk id, your secret paths
    nix build                 # the image
    nix run .#personalize -- ./result   # phase 2 fills the slot

The `host.nix` files are the substance: a host record is DATA (derivations and strings),
extracted from your evaluated `nixosSystem` with `builder.lib.extract`, with the live
variants declared as `extendModules` + a face from `builder.lib.mk`'s `modules`.

Every example is gated by the suite (`../run-all.sh`, targets `examples:test-example-*`):
each is evaluated against this checkout through the same API the flake exports, and every
endpoint its `flake.nix` publishes is forced to a `.drv`. So an example cannot drift from
the code, and cannot promise an endpoint the composer would refuse. What the gate does
not evaluate is the `flake.nix` wiring itself — it points at GitHub on purpose.
