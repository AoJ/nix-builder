{ pkgs, tools }:

let
  store = tools.store;

  asExt4 = store { name = "fixture"; rootPaths = [ pkgs.hello ]; shape = "ext4"; label = "nixos"; };
  asSquash = store { name = "fixture"; rootPaths = [ pkgs.hello ]; shape = "squashfs"; label = "nixos"; };
  asRoot = store {
    name = "fixture"; rootPaths = [ pkgs.hello ]; shape = "ext4"; label = "nixos";
    profile = pkgs.hello;
  };

  # Same builder, same inputs, a different derivation — so nix really builds it a second time.
  # Two builds of ONE derivation are the same store path, which is why nix cannot notice a
  # non-deterministic builder and why this has to be forced.
  again = img: img.overrideAttrs (_: { determinismProbe = "2"; });

  elsewhere = store { name = "other"; rootPaths = [ pkgs.hello ]; shape = "ext4"; label = "nixos"; };
in
pkgs.runCommand "test-store"
  { nativeBuildInputs = [ pkgs.e2fsprogs pkgs.squashfsTools ]; }
  ''
    set -euo pipefail

    echo "== ext4 carries the database itself =="
    debugfs -R "ls /nix/var/nix/db" ${asExt4.img} | tr ' ' '\n' | grep -q 'db.sqlite'
    [ ${builtins.toJSON asExt4.needsBootUnit} = false ]

    echo "== squashfs cannot, so it carries the dump — at the path the OS reads =="
    unsquashfs -l ${asSquash.img} | grep -q 'squashfs-root/nix-path-registration'
    [ ${builtins.toJSON asSquash.needsBootUnit} = true ]

    echo "== and that path is the one the tool declares, not one restated here =="
    [ ${builtins.toJSON asSquash.registrationPath} = /nix/store/nix-path-registration ]

    echo "== a profile makes ext4 a bootable ROOT: generation link, etc/NIXOS; bare stays bare =="
    debugfs -R "ls /nix/var/nix/profiles" ${asRoot.img} 2>/dev/null | grep -q 'system-1-link'
    debugfs -R "stat /etc/NIXOS" ${asRoot.img} > /dev/null 2>&1
    ! debugfs -R "stat /etc" ${asExt4.img} > /dev/null 2>&1


    echo "== built twice, byte for byte the same =="
    cmp ${asExt4.img} ${again asExt4.img}
    cmp ${asSquash.img} ${again asSquash.img}

    echo "== two names, two identities: no shared constant =="
    mine="$(dumpe2fs -h ${asExt4.img} 2>/dev/null | awk -F': *' '/Filesystem UUID/ { print $2 }')"
    theirs="$(dumpe2fs -h ${elsewhere.img} 2>/dev/null | awk -F': *' '/Filesystem UUID/ { print $2 }')"
    [ -n "$mine" ] && [ "$mine" != "$theirs" ]

    touch $out
  ''
