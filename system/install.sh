#!/usr/bin/env bash
# Installs the privileged half of the Omarchy OpenVPN widget.
#
#   sudo bash install.sh              install or update
#   sudo bash install.sh --uninstall  remove everything it installed
#
# Afterwards the panel can list profiles (through the cache, no prompt) and
# trigger writing actions through pkexec (the shell's auth dialog).
#
# The widget works without this. Status, throughput and connection details need
# no privileges at all; only profile management does.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/bin/omarchy-vpn-admin
POLICY=/usr/share/polkit-1/actions/org.omarchy.vpnadmin.policy
UNIT_DIR=/etc/systemd/system

[[ $EUID -eq 0 ]] || { echo "Please run with sudo." >&2; exit 1; }

if [[ ${1:-} == --uninstall ]]; then
  systemctl disable --now omarchy-vpn-cache.path 2>/dev/null || true
  rm -f "$BIN" "$POLICY" \
        "$UNIT_DIR/omarchy-vpn-cache.path" "$UNIT_DIR/omarchy-vpn-cache.service"
  rm -rf /var/lib/omarchy-vpn
  systemctl daemon-reload
  echo "removed."
  exit 0
fi

command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

# The helper runs as root through pkexec, so it must not be owned by, or
# writable for, the calling user — that would be a privilege escalation.
install -o root -g root -m 0755 "$HERE/omarchy-vpn-admin" "$BIN"
install -o root -g root -m 0644 "$HERE/org.omarchy.vpnadmin.policy" "$POLICY"
install -o root -g root -m 0644 "$HERE/omarchy-vpn-cache.path" "$UNIT_DIR/"
install -o root -g root -m 0644 "$HERE/omarchy-vpn-cache.service" "$UNIT_DIR/"

systemctl daemon-reload
systemctl enable --now omarchy-vpn-cache.path

# Fill it once so the panel has something to show straight away.
"$BIN" refresh

count=$(python3 -c "
import json
print(len(json.load(open('/var/lib/omarchy-vpn/profiles.json'))['profiles']))")

echo "installed:"
echo "  $BIN"
echo "  $POLICY"
echo "  $UNIT_DIR/omarchy-vpn-cache.{path,service}  (enabled)"
echo "  /var/lib/omarchy-vpn/profiles.json          ($count profiles)"
