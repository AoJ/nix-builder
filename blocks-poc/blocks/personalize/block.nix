{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;
in
{
  options = {
    name = mkOption { type = types.strMatching "[a-z0-9][a-z0-9-]*"; };

    slot = mkOption {
      type = types.attrsOf types.str;
      description = "The artifact face, as image declared it built. Verified against the artifact.";
    };

    files = mkOption {
      # Paths as STRINGS, resolved when the runner runs: a secret in a derivation is a
      # secret in the store, so nothing here may pull the source into one.
      type = types.listOf (types.submodule {
        options = {
          target = mkOption { type = types.strMatching "/.*"; };
          source = mkOption { type = types.str; };
        };
      });
    };

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          # A tool taking the artifact as its argument, not a derivation — this phase
          # must not be cached.
          run = mkOption { type = types.package; };
        };
      };
    };
  };

  config.out.run =
    let
      refuse = ''
        refuse() { echo "personalize: refusal: $1" >&2; exit 1; }
      '';

      copyIn = offVar: lib.concatMapStringsSep "\n" (f: ''
        mcopy -o -i "$artifact"@@"''$${offVar}" ${lib.escapeShellArg f.source} \
          ::${lib.escapeShellArg f.target}
        mcopy -i "$artifact"@@"''$${offVar}" ::${lib.escapeShellArg f.target} "$readback"
        cmp "$readback" ${lib.escapeShellArg f.source}
      '') config.files;

      byMedium = {
        # Nothing is copied until every check has passed.
        partition = pkgs.writeShellScript "personalize-${config.name}" ''
          set -euo pipefail
          ${refuse}
          artifact="$1"
          readback="$(mktemp)"
          num="$(${pkgs.gptfdisk}/bin/sgdisk -p "$artifact" \
            | awk -v n=${lib.escapeShellArg config.slot.name} '$NF == n { print $1 }')"
          [ -n "$num" ] || refuse "the artifact carries no partition named ${config.slot.name}"
          start="$(${pkgs.gptfdisk}/bin/sgdisk -i "$num" "$artifact" \
            | awk '/^First sector/ { print $3 }')"
          off=$(( start * 512 ))
          ${pkgs.mtools}/bin/mdir -i "$artifact"@@"$off" :: > /dev/null 2>&1 \
            || refuse "the slot at sector $start holds no filesystem"
          PATH=${pkgs.mtools}/bin:$PATH
          ${copyIn "off"}
        '';

        file = pkgs.writeShellScript "personalize-${config.name}" ''
          set -euo pipefail
          ${refuse}
          artifact="$1"
          readback="$(mktemp)"
          lba="$(${pkgs.xorriso}/bin/xorriso -indev "$artifact" \
            -find ${lib.escapeShellArg config.slot.path} -exec report_lba -- 2>/dev/null \
            | awk -F, '/^File data lba/ { gsub(/ /,"",$2); print $2 }')"
          [ -n "$lba" ] || refuse "the artifact carries no file at ${config.slot.path}"
          off=$(( lba * 2048 ))
          ${pkgs.mtools}/bin/mdir -i "$artifact"@@"$off" :: > /dev/null 2>&1 \
            || refuse "the file at ${config.slot.path} holds no filesystem"
          PATH=${pkgs.mtools}/bin:$PATH
          ${copyIn "off"}
        '';

        # The initramfs takes appended cpio segments as they come; the slot is the append
        # point itself, so the only check left is the readback.
        initrd-append = pkgs.writeShellScript "personalize-${config.name}" ''
          set -euo pipefail
          ${refuse}
          artifact="$1"
          [ -w "$artifact/initrd" ] || refuse "no writable initrd at $artifact"
          staged="$(mktemp -d)"
          ${lib.concatMapStringsSep "\n" (f: ''
            mkdir -p "$staged$(dirname ${lib.escapeShellArg f.target})"
            cp ${lib.escapeShellArg f.source} "$staged"${lib.escapeShellArg f.target}
          '') config.files}
          before="$(${pkgs.coreutils}/bin/stat -c%s "$artifact/initrd")"
          (cd "$staged" && find . -mindepth 1 | sort \
            | ${pkgs.cpio}/bin/cpio -o -H newc -R +0:+0 --reproducible --quiet) \
            >> "$artifact/initrd"
          ${lib.concatMapStringsSep "\n" (f: ''
            tail -c +$(( before + 1 )) "$artifact/initrd" \
              | ${pkgs.cpio}/bin/cpio -t --quiet \
              | grep -q ${lib.escapeShellArg (lib.removePrefix "/" f.target)}
          '') config.files}
        '';
      };
    in
    byMedium.${config.slot.medium};
}
