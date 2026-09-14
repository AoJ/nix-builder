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
      manifest = pkgs.writeText "${config.name}-personalize-manifest"
        (lib.concatMapStrings (f: "${f.source}\t${f.target}\n") config.files);

      runner = script: vars: runtimeInputs: tools.bashTool {
        name = "personalize-${config.name}";
        inherit runtimeInputs;
        text = vars + builtins.readFile script;
      };
    in
    {
      partition = runner ./partition.sh ''
        slot_name=${lib.escapeShellArg config.slot.name}
        manifest=${manifest}
      '' [ pkgs.coreutils pkgs.gawk pkgs.gptfdisk pkgs.mtools pkgs.diffutils ];

      file = runner ./file.sh ''
        slot_path=${lib.escapeShellArg config.slot.path}
        manifest=${manifest}
      '' [ pkgs.coreutils pkgs.gawk pkgs.xorriso pkgs.mtools pkgs.diffutils ];

      initrd-append = runner ./initrd-append.sh ''
        manifest=${manifest}
      '' [ pkgs.coreutils pkgs.findutils pkgs.cpio pkgs.gnugrep ];
    }.${config.slot.medium};
}
