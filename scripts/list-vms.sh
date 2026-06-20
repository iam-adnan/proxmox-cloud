#!/bin/bash
# Runs on the Proxmox host via self-hosted GitHub Actions runner.
# Usage: list-vms.sh <slack_user_id>
set -euo pipefail

SLACK_USER_ID="$1"
VM_LINES=""

while IFS= read -r VMID; do
  [ -z "$VMID" ] && continue

  # Only process VMs tagged with proxmox-cloud
  TAGS="$(qm config "$VMID" 2>/dev/null | grep '^tags:' | sed 's/^tags: //' || true)"
  echo "$TAGS" | grep -q "proxmox-cloud" || continue

  # Parse metadata from description. Proxmox percent-encodes the description in
  # `qm config` output, so URL-decode before parsing the JSON.
  DESC="$(qm config "$VMID" 2>/dev/null | grep '^description:' | sed 's/^description: //' || true)"
  OWNER="$(printf '%s' "$DESC" | python3 -c "import json,sys,urllib.parse; d=json.loads(urllib.parse.unquote(sys.stdin.read())); print(d.get('slack_user_id',''))" 2>/dev/null || true)"
  OS="$(printf '%s' "$DESC" | python3 -c "import json,sys,urllib.parse; d=json.loads(urllib.parse.unquote(sys.stdin.read())); print(d.get('os_type','unknown'))" 2>/dev/null || true)"

  [ "$OWNER" = "$SLACK_USER_ID" ] || continue

  NAME="$(qm config "$VMID" 2>/dev/null | grep '^name:' | awk '{print $2}')"
  STATUS="$(qm status "$VMID" 2>/dev/null | awk '{print $2}')"

  # Try to get current IP from guest agent (best effort)
  IP="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | \
    python3 -c "
import json, sys
try:
    ifaces = json.load(sys.stdin)
    for iface in ifaces:
        name = iface.get('name', '')
        if name.startswith(('eth', 'ens', 'enp', 'Ethernet')):
            for addr in iface.get('ip-addresses', []):
                if addr.get('ip-address-type') == 'ipv4':
                    ip = addr['ip-address']
                    if not ip.startswith('127.'):
                        print(ip)
                        break
except Exception:
    pass
" 2>/dev/null || echo "unknown")"

  STATUS_EMOJI=":white_circle:"
  [ "$STATUS" = "running" ] && STATUS_EMOJI=":green_circle:"
  [ "$STATUS" = "stopped" ] && STATUS_EMOJI=":red_circle:"

  VM_LINES="${VM_LINES}\n${STATUS_EMOJI} \`${NAME}\`  •  ${OS}  •  IP: \`${IP}\`  •  ${STATUS}"
done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')

if [ -z "$VM_LINES" ]; then
  MSG=":computer: You have no VMs.\nCreate one with \`/create-vm <ubuntu|amazon-linux|windows-server> <name>\`"
else
  MSG=":computer: *Your VMs:*${VM_LINES}"
fi

curl -sf -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg ch "$SLACK_USER_ID" --arg txt "$MSG" '{channel: $ch, text: $txt, mrkdwn: true}')"
