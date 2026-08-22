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
BIN=/usr/local/bin/multivpn-admin
POLICY=/usr/share/polkit-1/actions/software.nepomuk.multivpn.policy
UNIT_DIR=/etc/systemd/system

[[ $EUID -eq 0 ]] || { echo "Please run with sudo." >&2; exit 1; }

# Earlier versions installed under an omarchy-* name, which claimed a namespace
# this plugin does not own. Clean those up whichever way the script is run.
remove_legacy() {
  systemctl disable --now omarchy-vpn-cache.path 2>/dev/null || true
  rm -f /usr/local/bin/omarchy-vpn-admin \
        /usr/share/polkit-1/actions/org.omarchy.vpnadmin.policy \
        "$UNIT_DIR/omarchy-vpn-cache.path" "$UNIT_DIR/omarchy-vpn-cache.service"
  rm -rf /var/lib/omarchy-vpn
}

if [[ ${1:-} == --uninstall ]]; then
  systemctl disable --now multivpn-cache.path 2>/dev/null || true
  rm -f "$BIN" "$POLICY" \
        "$UNIT_DIR/multivpn-cache.path" "$UNIT_DIR/multivpn-cache.service"
  rm -rf /var/lib/multivpn
  remove_legacy
  systemctl daemon-reload
  echo "removed."
  exit 0
fi

remove_legacy

command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

# The helper runs as root through pkexec, so it must not be owned by, or
# writable for, the calling user — that would be a privilege escalation.
install -o root -g root -m 0755 "$HERE/multivpn-admin" "$BIN"
install -o root -g root -m 0644 "$HERE/software.nepomuk.multivpn.policy" "$POLICY"
install -o root -g root -m 0644 "$HERE/multivpn-cache.path" "$UNIT_DIR/"
install -o root -g root -m 0644 "$HERE/multivpn-cache.service" "$UNIT_DIR/"

systemctl daemon-reload
systemctl enable --now multivpn-cache.path

# Fill it once so the panel has something to show straight away.
"$BIN" refresh

count=$(python3 -c "
import json
print(len(json.load(open('/var/lib/multivpn/profiles.json'))['profiles']))")

echo "installed:"
echo "  $BIN"
echo "  $POLICY"
echo "  $UNIT_DIR/multivpn-cache.{path,service}  (enabled)"
echo "  /var/lib/multivpn/profiles.json          ($count profiles)"
