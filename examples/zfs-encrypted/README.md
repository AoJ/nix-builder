# An encrypted zfs host

Encryption is a property of the storage layout, and it follows the install (law L3): no
image is ever encrypted, because a pool created with a store-visible placeholder
passphrase is compromised for its whole life — `zfs change-key` rewrites neither the
master key nor the previous wrapped key on disk. The pool is therefore created **at
install time, with the real passphrase**, and the passphrase arrives the same way every
other secret does.

## The key's whole path

| step | who does it | where it lives |
|---|---|---|
| the passphrase is generated | you, once, into your vault | never in the store, never in an artifact on disk |
| it enters the record | `secrets.files` — one more file in the same `embedded` delivery | `/run/secrets/example-zfs-enc/pool.pass` at phase-2 time |
| phase 2 writes it | the personalize runner | the installer artifact's slot, beside the host key |
| the installer reads it | its slot-key service, at boot | `/tmp/zfs_root_key` in RAM |
| the pool is created with it | `install.prepare` | as the pool's passphrase — `keyformat=passphrase` |
| the act delivers it | `install.poolKeyDestination` | `/var/keys/pool.key` on the installed system |
| the bootloader carries it | `boot.initrd.secrets` in the host's own configuration | inside the initrd on the ESP |
| stage 1 unlocks with it | zfs, because `keylocation` names that initrd path | — |

Three of those lines are declarations you make, and they must agree: the file in
`secrets.files`, `install.poolKeyDestination`, and the `keylocation` + `boot.initrd.secrets`
pair in the configuration. [`host.nix`](host.nix) binds them through two `let` values
(`poolKeyTarget`, `poolKeyInitrd`) so the agreement is visible in one place.

There is no prompt anywhere, deliberately: full automation is the goal, and a host that
wants an interactive unlock changes its layout, not its delivery.

## What `encrypted = true` buys you

It is a refusal criterion, not decoration. An encrypted host whose passphrase was never
delivered — an installer nobody personalized — is stopped **before any wipe**, because
the alternative is a `zpool create` that fails with the disk already cleared. The same
declaration also makes the act refuse a mismatch: an encrypted host finding a plain pool,
or the reverse, stops rather than silently landing on the wrong thing.

## What it costs, honestly

The key sits in plaintext inside the initrd on the ESP, which is not encrypted. That is
what makes an unattended boot possible at all, and whether it is protection enough is
this host's call: it already achieves "no plaintext data at rest" for the pool, and a
host needing more reaches for a TPM, a remote unlock, or deploy-time delivery — outside
the builder either way.

## The sequence

    nix build                                    # the installer artifact
    nix run .#personalize-kexec -- ./result      # host key AND pool passphrase into the slot
    # kexec it on the target; it creates the encrypted pool and reboots into it unattended
