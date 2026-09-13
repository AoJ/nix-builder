{ pkgs, lib }:

{ system, bootloader, entries }:

let
  efiFileName = {
    "x86_64-linux" = "BOOTX64.EFI";
    "aarch64-linux" = "BOOTAA64.EFI";
  }.${system};
in
pkgs.runCommand "esp.img"
  { nativeBuildInputs = [ pkgs.dosfstools pkgs.mtools pkgs.coreutils ]; }
  ''
    set -euo pipefail
    staged="$(mktemp -d)"
    mkdir -p "$staged/EFI/BOOT" "$staged/loader/entries"
    cp ${bootloader} "$staged/EFI/BOOT/${efiFileName}"
    printf 'timeout 1\ndefault nixos\n' > "$staged/loader/loader.conf"
    ${lib.concatMapStringsSep "\n" (e: ''
      cp ${e.kernel} "$staged/${e.name}-kernel"
      cp ${e.initrd} "$staged/${e.name}-initrd"
      {
        printf 'title %s\n' ${lib.escapeShellArg e.title}
        printf 'linux /%s-kernel\n' ${lib.escapeShellArg e.name}
        printf 'initrd /%s-initrd\n' ${lib.escapeShellArg e.name}
        printf 'options %s\n' ${lib.escapeShellArg (lib.concatStringsSep " " e.kernelParams)}
      } > "$staged/loader/entries/${e.name}.conf"
    '') entries}

    content_kib="$(du -sk "$staged" | cut -f1)"
    size_mib=$(( (content_kib + 1023) / 1024 + 4 ))
    [ "$size_mib" -ge 36 ] || size_mib=36

    truncate -s "''${size_mib}M" "$out"
    mkfs.fat -F 32 -n ESP -i deadbeef "$out"
    (cd "$staged" && find . -mindepth 1 -type d -printf '%P\n' | sort \
      | while IFS= read -r d; do mmd -i "$out" "::/$d"; done)
    (cd "$staged" && find . -mindepth 1 -type f -printf '%P\n' | sort \
      | while IFS= read -r f; do mcopy -i "$out" "$f" "::/$f"; done)
  ''
