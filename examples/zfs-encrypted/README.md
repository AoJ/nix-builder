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
| it enters the declaration | `secrets.files` — one more file in the same delivery, named by this host | `content.file` here; a deploy holding it in a variable would say `content.env` |
| phase 2 writes it | the personalize runner | the installer artifact's slot, beside the host key |
| the installer lays the slot out | the install act | `builder.lib.paths.installSlot` — the builder's own path, in RAM |
| the pool is created with it | this host's `install.prepare` | `keylocation=file://${installSlot}/pool.pass`, then repointed at the initrd path |
| the act fills the target's slot | the install act | the partition named `slotName` in this host's layout |
| the bootloader carries it | `boot.initrd.secrets`, reading this host's own slot mount | inside the initrd on the ESP |
| stage 1 unlocks with it | zfs, because `keylocation` names that initrd path | — |

**Nothing in that chain tells the builder what the file is.** It carries bytes to a name
this host chose; every line that knows `pool.pass` is a passphrase is this host's own —
its `prepare`, its slot mount, its `boot.initrd.secrets`. [`host.nix`](host.nix) binds
them through two `let` values (`slotMount`, `poolKeyInitrd`) so the agreement is visible
in one place.

One ordering constraint worth knowing: the bootloader step that bakes the initrd secret
runs **during** `nixos-install`, so this host's `prepare` mounts its slot under `/mnt`
before that — and the act, finding the partition already mounted, fills it there rather
than mounting it a second time.

There is no prompt anywhere, deliberately: full automation is the goal, and a host that
wants an interactive unlock changes its layout, not its delivery.

## What `encrypted = true` buys you

It makes the act refuse a mismatch: an encrypted host finding a plain pool, or the
reverse, stops rather than silently landing on the wrong thing.

The other refusal needs no such declaration and protects every host: the act checks that
the files this host said its slot carries actually **arrived**, before anything
destructive. An installer nobody personalized is therefore stopped before any wipe,
rather than clearing a disk and failing the create for want of a passphrase — and the
check never looks at what any of those files are.

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
