# Witness that the EXAMPLE's OWN fileSystems mount of /run/secrets came up — the mount the
# example config declares (the marker mounts the partition its own way; this checks the entry
# the example actually wrote), recorded before the marker powers the guest off.
{ record }:
{ pkgs, ... }:
{
  systemd.services.e2e-example-slot = {
    wantedBy = [ "multi-user.target" ];
    before = [ "e2e-marker.service" ];
    serviceConfig.Type = "oneshot";
    path = [ record pkgs.util-linux ];
    script = ''
      if mountpoint -q /run/secrets; then
        e2e-record "E2E-EXAMPLE-SLOT-MOUNTED"
      else
        e2e-record "E2E-EXAMPLE-SLOT-UNMOUNTED"
      fi
    '';
  };
}
