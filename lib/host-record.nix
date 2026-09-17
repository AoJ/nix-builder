# THE HOST RECORD — what a consumer hands the composer, stated as options.
#
# Every block in here declares its contract as an option interface; the record was the one
# surface that did not, so a missing field surfaced as `attribute 'machine' missing` deep
# in a trace and a typo'd `slotname` silently became a different host. Typed, it answers
# the two questions an example otherwise has to answer in prose: what must be provided,
# and where does each thing come from.
#
# The record is DATA — derivations and strings — never a NixOS configuration. `lib.extract`
# produces the variant halves from an evaluated system; everything else the host states.
#
# Required fields have no default: a host that never reaches an endpoint needing one never
# trips over it (a squashfs appliance has no installer, so it states no `install`).
{ lib }:

let
  inherit (lib) mkOption types;

  machineType = types.submodule {
    options = {
      kernelPackages = mkOption {
        type = types.raw;
        description = "The kernel the target runs — the installer boots the same one.";
      };
      initrdAvailableKernelModules = mkOption { type = types.listOf types.str; default = [ ]; };
      initrdKernelModules = mkOption { type = types.listOf types.str; default = [ ]; };
      kernelModules = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Includes the machine's watchdog driver, if it has one.";
      };
      firmware = mkOption { type = types.listOf types.package; default = [ ]; };
    };
  };

  # What `lib.extract` returns for one evaluated system. Paths rather than packages on
  # purpose: the extraction hands over `${toplevel}/kernel`, a store SUBPATH with context.
  variantOptions = {
    toplevel = mkOption {
      type = types.package;
      description = "The system this variant packs.";
    };
    kernel = mkOption { type = types.path; };
    initrd = mkOption { type = types.path; };
    espBinary = mkOption {
      type = types.path;
      description = "The bootloader binary from the TARGET's own systemd — an aarch64 host's aa64 one, never the runner's.";
    };
    kernelParams = mkOption { type = types.listOf types.str; default = [ ]; };
    rootMode = mkOption {
      type = types.enum [ "disk" "memory" ];
      description = "Derived by the extraction: a tmpfs root is what memory-rooted means.";
    };
    machine = mkOption {
      type = types.nullOr machineType;
      default = null;
      description = "Read from the runtime variant only; a live variant carries it unused.";
    };
  };
in
{
  options = {
    name = mkOption {
      type = types.strMatching "[a-z0-9][a-z0-9-]*";
      description = "Names every artifact this host produces, and seeds the iso volume ids.";
    };

    system = mkOption {
      type = types.enum [ "x86_64-linux" "aarch64-linux" ];
      description = "The architecture the host boots on — and the one its installer is built for.";
    };

    slotName = mkOption {
      type = types.strMatching "[a-z0-9][a-z0-9-]*";
      description = ''
        The slot: the partition (or file, per format) phase 2 writes into. The host's ONE
        declaration of it — the storage layout that provides the partition and this field
        must name the same thing, and there is deliberately no default, so a typo fails
        here instead of producing an artifact whose slot nothing can find.
      '';
    };

    variants = mkOption {
      description = ''
        The same host in the shapes the formats need. Each is `lib.extract` applied to an
        evaluated system: the runtime one, and the live ones built with `extendModules`
        plus a face from `lib.mk`'s `modules` — a live format packs a DIFFERENT toplevel,
        which is why it cannot be derived from the runtime one.
      '';
      type = types.submodule {
        options = {
          runtime = mkOption {
            description = "The host as it runs. What every install installs, and what the disk formats pack.";
            type = types.submodule {
              options = variantOptions // {
                machine = mkOption {
                  type = machineType;
                  description = ''
                    The target machine as the host declares it. The installer is built from
                    it, so it boots exactly where the host boots and carries nothing the
                    host did not claim to need.
                  '';
                };
                storage = mkOption {
                  type = types.enum [ "zfs" "ext4" "squashfs" ];
                  description = ''
                    What the host's root filesystem IS. It decides which endpoints exist:
                    zfs makes the runtime disk images holes (the pool is created by the
                    install, L2), squashfs makes every installer a hole (the image writes
                    that store, L6).
                  '';
                };
              };
            };
          };
          liveNetboot = mkOption {
            description = "The host wearing the netboot face — packed by the kexec and ipxe endpoints.";
            type = types.submodule { options = variantOptions; };
          };
          liveIso = mkOption {
            description = ''
              The host wearing the iso face, as a FUNCTION of the medium's volume label:
              the label is derived by the composer from the artifact's name, so only it can
              supply one.
            '';
            type = types.functionTo (types.submodule { options = variantOptions; });
          };
        };
      };
    };

    secrets = mkOption {
      description = ''
        How this host's secrets reach it. NOTHING here produces a secret: the builder never
        generates a key, and no secret ever enters the store. The host states which
        deliveries it uses and where the files will be READ FROM when a runner runs.
      '';
      type = types.submodule {
        options = {
          delivery = mkOption {
            type = types.listOf (types.enum [ "embedded" "sidecar" "deploy" "external" ]);
            description = ''
              The set of ways this host gets its secrets — combinable, and empty is valid
              (every endpoint still exists and quietly does nothing). `embedded` means the
              artifact carries them in its slot and phase 2 puts them there; `sidecar` means
              a separate artifact beside the image. `deploy` and `external` are declarations
              about what happens outside the builder, and a member with no producer here
              fails at eval rather than leaving a host to boot without an identity.
            '';
          };
          files = mkOption {
            default = [ ];
            description = "What lands in the slot (phase 2) and in a sidecar.";
            type = types.listOf (types.submodule {
              options = {
                target = mkOption {
                  type = types.strMatching "/.*";
                  description = "Where the file lands INSIDE the slot or sidecar.";
                };
                source = mkOption {
                  type = types.str;
                  description = ''
                    Where phase 2 reads the file from: a path on the machine running the
                    personalize runner, resolved THEN — not a store path, not a derivation,
                    and not something this repo creates. The host's age identity is
                    generated outside (`age-keygen`), its sops bundle is encrypted to that
                    identity's public half, and a deploy drops both here at run time.
                  '';
                };
                runtimeSource = mkOption {
                  type = types.str;
                  description = "The same file for the SIDECAR producer; usually identical to source.";
                };
              };
            });
          };
          bundle = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              The host's sops bundle, as a runtime path. Setting it turns on phase 2's
              recipient check: the key being planted must have its public half among this
              bundle's recipients, or the run refuses before touching the artifact —
              because the alternative is a machine that boots unable to decrypt anything.
              Null means no such check.
            '';
          };
          keyTarget = mkOption {
            type = types.nullOr (types.strMatching "/.*");
            default = null;
            description = "Which `files` target IS the age identity — what the recipient check verifies. Required alongside `bundle`.";
          };
        };
      };
    };

    install = mkOption {
      default = { };
      description = ''
        What the install act needs. Consumed only by the `-install` endpoints, so a host
        with none (a squashfs appliance, L6) states nothing here at all.
      '';
      type = types.submodule {
        options = {
          prepare = mkOption {
            type = types.package;
            description = ''
              Brings the target's storage into existence AND mounts it at /mnt — disko's
              own create script, or an equivalent. Runs under the action's PATH (nix, zfs,
              util-linux, coreutils); anything else is spelled absolutely.
            '';
          };
          mount = mkOption {
            type = types.package;
            description = ''
              Mounts an ALREADY-INSTALLED target at /mnt. This is the never-reformat path:
              the act runs it first, and only a target it cannot mount gets created.
            '';
          };
          disks = mkOption {
            type = types.nonEmptyListOf types.str;
            description = ''
              The whole disks the target lives on, by stable identity (/dev/disk/by-id/…).
              This is the wipe's blast radius: a create clears exactly these and nothing
              beside them, and the act refuses outright if one of them carries the running
              system.
            '';
          };
          pool = mkOption {
            type = types.str;
            default = "";
            description = "The zfs pool the act probes, mismatch-checks and exports; empty for a plain filesystem.";
          };
          encrypted = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Whether the target pool is encrypted — the layout's own property (L3). It is
              a refusal criterion: an encrypted host whose pool passphrase was not
              delivered is stopped BEFORE any wipe, since the create would otherwise fail
              with the disk already cleared.
            '';
          };
          keyDestination = mkOption {
            type = types.str;
            description = "Where the host's age identity lands on the installed system.";
          };
          poolKeyDestination = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Where the install delivers the pool passphrase on the target, for the
              layout's boot-time unlock to read. Where it must sit to be readable BEFORE
              the pool unlocks is the layout's business (an initrd secret, typically);
              null delivers nothing.
            '';
          };
          report = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "An executable the installer calls with one line per milestone; null reports nothing.";
          };
        };
      };
    };
  };
}
