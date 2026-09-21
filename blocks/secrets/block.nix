{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;
in
{
  options = {
    name = mkOption { type = types.strMatching "[a-z0-9][a-z0-9-]*"; };

    files = mkOption {
      # What goes where, and where the bytes come from — never what they are. `text` is
      # already in the store by the time it gets here; `env` and `file` are resolved when
      # the runner runs, because a secret in a derivation is a secret in the store.
      type = types.listOf (types.submodule {
        options = {
          target = mkOption { type = types.strMatching "/.*"; };
          mode = mkOption { type = types.strMatching "0[0-7][0-7][0-7]"; default = "0400"; };
          content = mkOption {
            type = types.submodule {
              options = {
                text = mkOption { type = types.nullOr types.str; default = null; };
                env = mkOption { type = types.nullOr types.str; default = null; };
                file = mkOption { type = types.nullOr types.str; default = null; };
              };
            };
          };
        };
      });
    };

    sidecarFormat = mkOption {
      type = types.enum [ "vfat" "iso" "json" ];
      description = "The form the consumer takes the sidecar in: a filesystem it mounts, or a format it reads.";
    };

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          # A tool taking the destination as its argument, not a derivation — see files.
          run = mkOption { type = types.package; };
          fs = mkOption { type = types.str; };
          # How the running system FINDS this sidecar — the block generates the identity,
          # so it must hand it back, or a consumer has nothing to mount by.
          label = mkOption {
            type = types.nullOr types.str;
            description = ''
              The volume label at /dev/disk/by-label/ for a mountable sidecar: the fixed
              SECRETS for vfat, the name-derived volume id for iso. Null for json, which is
              read as a file, not mounted.
            '';
          };
          volumeId = mkOption {
            type = types.nullOr types.str;
            description = ''
              The 32-bit volume id the medium carries (the FAT serial for vfat, the iso9660
              volume id for iso — which is also its label). Null for json. For a consumer
              that finds the device by uuid rather than by label.
            '';
          };
        };
      };
    };
  };

  config.out =
    let
      manifest = tools.secretManifest { inherit (config) name files; };

      volumeId = tools.ids.volumeId "${config.name}:sidecar";

      runner = script: vars: runtimeInputs: tools.bashTool {
        name = "sidecar-${config.name}";
        inherit runtimeInputs;
        text = vars
          + builtins.readFile tools.secretResolve
          + builtins.readFile script;
      };

      byFormat = {
        vfat = runner ./sidecar-vfat.sh ''
          fat_image=${lib.getExe tools.fatImageApp}
          label=SECRETS
          volume_id=${lib.escapeShellArg volumeId}
          size_bytes=${toString (4 * 1048576)}
          manifest=${manifest}
        '' [ pkgs.coreutils ];

        iso = runner ./sidecar-iso.sh ''
          volume_id=${lib.escapeShellArg (lib.toUpper volumeId)}
          manifest=${manifest}
        '' [ pkgs.coreutils pkgs.xorriso ];

        json = runner ./sidecar-json.sh ''
          manifest=${manifest}
        '' [ pkgs.coreutils pkgs.jq ];
      };
      # The by-label handle and the raw volume id per format — the SAME values baked into
      # the runners above, read back here so a consumer mounts by exactly what was written.
      # vfat carries the fixed SECRETS label and the id as its FAT serial; iso's volume id
      # IS its label (uppercased, iso9660 has no separate serial); json is a file.
      isoVolid = lib.toUpper volumeId;
      label = { vfat = "SECRETS"; iso = isoVolid; json = null; }.${config.sidecarFormat};
      volId = { vfat = volumeId; iso = isoVolid; json = null; }.${config.sidecarFormat};
    in
    {
      run = byFormat.${config.sidecarFormat};
      fs = { vfat = "vfat"; iso = "iso9660"; json = "json"; }.${config.sidecarFormat};
      inherit label;
      volumeId = volId;
    };
}
