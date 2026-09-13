# Proposed contracts for the blocks described in wip/blocks-design.md.
#
# Interfaces only — every `out` is declared, none is implemented. `blocks/image` is left out
# because it exists for real in docs/blocks/blocks-poc/blocks/image/block.nix; this file is the
# other four, written in the same shape so they can be read side by side.
#
# The design is docs/blocks/blocks-design.md. The endpoint set these serve is
# wip/plan-image-build.md.

{ lib }:

let
  inherit (lib) mkOption types;

  systems = [ "x86_64-linux" "aarch64-linux" ];

  # A slot is a directory in a finished artifact. Where it is, is a property of the format.
  slotType = types.submodule {
    options = {
      medium = mkOption { type = types.enum [ "esp" "file" "partition" "initrd" ]; };
      path = mkOption {
        type = types.nullOr types.str;
        description = "File path or partition name, for the media that need one.";
      };
      mountPoint = mkOption { type = types.str; };
    };
  };
in
{
  ##########################################################################
  # install — wraps a host in an OS that unpacks it. system in, system out.
  ##########################################################################
  install = {
    toplevel = mkOption {
      type = types.package;
      description = "The system to be installed.";
    };

    closure = mkOption {
      type = types.listOf types.package;
      description = "What the installer carries, so it can install offline.";
    };

    prepare = mkOption {
      type = types.package;
      description = "Brings the target's storage into existence. The block does not know its shape.";
    };

    mount = mkOption {
      type = types.package;
      description = "Mounts that storage where the install writes.";
    };

    keyDestination = mkOption {
      type = types.str;
      description = "Where the installed system's key lands, once the target exists.";
    };

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          system = mkOption {
            type = types.unspecified;
            description = "The installer. Goes to `image`, which does not know it is one.";
          };
        };
      };
    };
  };

  ##########################################################################
  # store — store paths in, a filesystem holding them out, DB registered.
  ##########################################################################
  store = {
    rootPaths = mkOption {
      type = types.listOf types.package;
      description = "Roots whose closure the filesystem carries.";
    };

    shape = mkOption {
      type = types.enum [ "ext4" "squashfs" ];
      description = "How the store is held. Both register the database.";
    };

    label = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Filesystem label, where the shape has one.";
    };

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          img = mkOption { type = types.package; };
          fs = mkOption { type = types.str; };
          registered = mkOption {
            type = types.bool;
            description = "Declared so a test can assert it, not so a caller can turn it off.";
          };
        };
      };
    };
  };

  ##########################################################################
  # secrets — files in, a sidecar out. Nothing boots.
  ##########################################################################
  secrets = {
    files = mkOption {
      type = types.listOf (types.submodule {
        options = {
          target = mkOption { type = types.strMatching "/.*"; };
          source = mkOption { type = types.path; };
        };
      });
    };

    medium = mkOption {
      type = types.enum [ "iso" "vfat" "json" ];
      description = "How the consumer takes the data. Mounting is one way of taking it.";
    };

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          file = mkOption { type = types.package; };
          fs = mkOption { type = types.str; };
        };
      };
    };
  };

  ##########################################################################
  # personalize — phase two. A finished artifact gains the files its slot is for.
  ##########################################################################
  personalize = {
    artifact = mkOption {
      type = types.path;
      description = "A FINISHED artifact. Not a derivation: this phase must not be cached.";
    };

    format = mkOption {
      type = types.enum [ "iso" "raw" "qcow2" "kexec" "ipxe" ];
      description = "Decides how the slot is found. The artifact does not say.";
    };

    slot = mkOption { type = slotType; };

    files = mkOption {
      type = types.listOf (types.submodule {
        options = {
          target = mkOption { type = types.strMatching "/.*"; };
          source = mkOption { type = types.path; };
        };
      });
    };

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          # A tool, not a derivation — a secret in a derivation is a secret in the store.
          run = mkOption { type = types.package; };
        };
      };
    };
  };

  inherit systems slotType;
}
