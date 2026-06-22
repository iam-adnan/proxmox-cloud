#!/bin/bash
# Runs on the Proxmox host via self-hosted GitHub Actions runner.
# Lists the requesting user's VMs (qm) and containers (pct).
# Usage: list-vms.sh <slack_user_id>
set -euo pipefail

SLACK_USER_ID="$1"
LINES=""

# Decode a metadata key from a (percent-encoded) description JSON. Proxmox
# percent-encodes the description in `qm/pct config` output, so URL-decode first.
meta() { # <description> <key>
  printf '%s' "$1" | python3 -c "
import json,sys,urllib.parse
try:
    d=json.loads(urllib.parse.unquote(sys.stdin.read()))
    print(d.get('$2',''))
except Exception:
    pass
" 2>/dev/null || true
}

# Append one line for a resource the user owns. Args: <kind vm|ct> <id>
emit() {
  local KIND="$1" ID="$2" CONF NAME STATUS IP OS NOTE TAGS DESC

  if [ "$KIND" = "vm" ]; then
    CONF="$(qm config "$ID" 2>/dev/null || true)"
  else
    CONF="$(pct config "$ID" 2>/dev/null || true)"
  fi
  [ -z "$CONF" ] && return 0

  TAGS="$(printf '%s\n' "$CONF" | grep '^tags:' | sed 's/^tags: //' || true)"
  printf '%s' "$TAGS" | grep -q "proxmox-cloud" || return 0

  DESC="$(printf '%s\n' "$CONF" | grep '^description:' | sed 's/^description: //' || true)"
  [ "$(meta "$DESC" slack_user_id)" = "$SLACK_USER_ID" ] || return 0

  OS="$(meta "$DESC" os_type)"; [ -z "$OS" ] && OS="unknown"
  NOTE="$(meta "$DESC" note)"

  if [ "$KIND" = "vm" ]; then
    NAME="$(printf '%s\n' "$CONF" | grep '^name:' | awk '{print $2}')"
    STATUS="$(qm status "$ID" 2>/dev/null | awk '{print $2}')"
    IP="$(qm guest cmd "$ID" network-get-interfaces 2>/dev/null | \
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
  else
    NAME="$(printf '%s\n' "$CONF" | grep '^hostname:' | awk '{print $2}')"
    STATUS="$(pct status "$ID" 2>/dev/null | awk '{print $2}')"
    IP="$(pct exec "$ID" -- ip -4 -o addr show dev eth0 2>/dev/null \
      | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -1 || true)"
  fi
  [ -z "$IP" ] && IP="unknown"

  local EMOJI=":white_circle:"
  [ "$STATUS" = "running" ] && EMOJI=":green_circle:"
  [ "$STATUS" = "stopped" ] && EMOJI=":red_circle:"

  local KINDTAG="[VM]"; [ "$KIND" = "ct" ] && KINDTAG="[CT]"
  local SUFFIX=""; [ -n "$NOTE" ] && SUFFIX="  •  _${NOTE}_"
  LINES="${LINES}\n${EMOJI} ${KINDTAG} \`${NAME}\`  •  ${OS}  •  IP: \`${IP}\`  •  ${STATUS}${SUFFIX}"
}

# VMs
while IFS= read -r ID; do
  [ -n "$ID" ] && emit vm "$ID"
done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')

# Containers
while IFS= read -r ID; do
  [ -n "$ID" ] && emit ct "$ID"
done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')

if [ -z "$LINES" ]; then
  MSG=":computer: You have no VMs or containers.\nCreate one with \`/create-vm\`."
else
  MSG=":computer: *Your resources:*${LINES}"
fi

curl -sf -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg ch "$SLACK_USER_ID" --arg txt "$MSG" '{channel: $ch, text: $txt, mrkdwn: true}')"
