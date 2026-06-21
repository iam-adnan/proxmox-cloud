#!/bin/bash
# Runs on the Proxmox host via self-hosted GitHub Actions runner.
# Usage: create-vm.sh <os_type> <vm_name> <slack_user_id> [memory_mb] [disk_gb]
set -euo pipefail

OS_TYPE="$1"
VM_NAME="$2"
SLACK_USER_ID="$3"
MEMORY_MB="${4:-2048}"
DISK_GB="${5:-25}"

STORAGE="${PROXMOX_STORAGE:-local-lvm}"
NODE="${PROXMOX_NODE:-pve}"

# ── Resolve template and default user ────────────────────────────────────────
case "$OS_TYPE" in
  ubuntu)
    TEMPLATE_ID="${PROXMOX_UBUNTU_TEMPLATE_ID}"
    SSH_USER="ubuntu"
    ;;
  amazon-linux)
    TEMPLATE_ID="${PROXMOX_AMAZON_LINUX_TEMPLATE_ID}"
    SSH_USER="ec2-user"
    ;;
  windows-server)
    TEMPLATE_ID="${PROXMOX_WINDOWS_TEMPLATE_ID}"
    SSH_USER="Administrator"
    ;;
  *)
    echo "ERROR: Unknown OS type: $OS_TYPE" >&2
    exit 1
    ;;
esac

# ── Get next available VMID ───────────────────────────────────────────────────
VMID=$(pvesh get /cluster/nextid)
echo ">> Creating VM '$VM_NAME' (VMID=$VMID, OS=$OS_TYPE, template=$TEMPLATE_ID, mem=${MEMORY_MB}MB, disk=${DISK_GB}GB)"

# ── Clone template ────────────────────────────────────────────────────────────
qm clone "$TEMPLATE_ID" "$VMID" \
  --name "$VM_NAME" \
  --full \
  --storage "$STORAGE"

# ── Apply requested memory ───────────────────────────────────────────────────
qm set "$VMID" --memory "$MEMORY_MB"

# ── Grow the disk if a larger size was requested (qm can only grow, not shrink).
# Template disk is 25G; cloud-init growpart expands the filesystem on first boot.
CUR_GB="$(qm config "$VMID" | sed -n 's/^scsi0:.*size=\([0-9]\+\)G.*/\1/p')"
if [ -n "$CUR_GB" ] && [ "$DISK_GB" -gt "$CUR_GB" ]; then
  echo ">> Resizing scsi0 from ${CUR_GB}G to ${DISK_GB}G"
  qm disk resize "$VMID" scsi0 "${DISK_GB}G"
elif [ -n "$CUR_GB" ] && [ "$DISK_GB" -lt "$CUR_GB" ]; then
  echo ">> Requested ${DISK_GB}G < template ${CUR_GB}G; keeping ${CUR_GB}G (cannot shrink)."
fi

# Store owner metadata in VM description so we can enforce per-user ops later
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
qm set "$VMID" \
  --description "{\"slack_user_id\":\"$SLACK_USER_ID\",\"os_type\":\"$OS_TYPE\",\"created_at\":\"$CREATED_AT\"}" \
  --tags "proxmox-cloud"

# ── Linux: inject SSH key via cloud-init ─────────────────────────────────────
SSH_KEY_CONTENT=""
SSH_PASS=""

if [ "$OS_TYPE" != "windows-server" ]; then
  # Use a private temp *directory* — mktemp on a file would pre-create the path,
  # and ssh-keygen then prompts "Overwrite (y/n)?" and aborts on the
  # non-interactive runner. A fresh dir lets ssh-keygen create the key itself.
  KEY_DIR="$(mktemp -d /tmp/vm-key-XXXXXX)"
  KEY_FILE="${KEY_DIR}/id_ed25519"
  trap "rm -rf ${KEY_DIR}" EXIT

  ssh-keygen -t ed25519 -f "$KEY_FILE" -C "proxmox-cloud@${VM_NAME}" -N "" -q

  # Ensure cloud-init drive exists on cloned VM
  if ! qm config "$VMID" | grep -q "^ide[0-9].*cloudinit"; then
    qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  fi

  qm set "$VMID" \
    --ciuser "$SSH_USER" \
    --sshkeys "${KEY_FILE}.pub" \
    --ipconfig0 ip=dhcp

  SSH_KEY_CONTENT="$(cat "$KEY_FILE")"
fi

# ── Start VM ─────────────────────────────────────────────────────────────────
qm start "$VMID"
echo ">> VM started — waiting for guest agent to report an IP..."

# ── Wait for IP via QEMU guest agent ─────────────────────────────────────────
# Generous window to cover first boot, cloud-init, and DHCP on a busy host.
MAX_WAIT=420
ELAPSED=0
IP=""

while [ -z "$IP" ] && [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  sleep 10
  ELAPSED=$((ELAPSED + 10))

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
" 2>/dev/null || true)"
done

if [ -z "$IP" ]; then
  echo "ERROR: VM did not obtain an IP within ${MAX_WAIT}s." >&2
  qm stop "$VMID" || true
  qm destroy "$VMID" --purge || true
  exit 1
fi

echo ">> VM is reachable at $IP"

# ── Windows: set password + enable OpenSSH via guest agent ───────────────────
if [ "$OS_TYPE" = "windows-server" ]; then
  echo ">> Waiting for Windows to finish booting..."
  sleep 60

  # Generate a compliant password: base + Aa1! to satisfy complexity rules
  BASE="$(openssl rand -base64 12 | tr -d '+/=')"
  WIN_PASS="${BASE}Aa1!"
  SSH_PASS="$WIN_PASS"

  qm guest exec "$VMID" -- \
    powershell.exe -NonInteractive -Command \
    "net user Administrator '${WIN_PASS}'" \
    2>&1 | tail -1

  qm guest exec "$VMID" -- \
    powershell.exe -NonInteractive -Command \
    "if (-not (Get-WindowsCapability -Online -Name OpenSSH.Server* | Where-Object State -eq Installed)) { \
       Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 \
     }; \
     Start-Service sshd; \
     Set-Service -Name sshd -StartupType Automatic" \
    2>&1 | tail -3
fi

# ── Send Slack DM with credentials ───────────────────────────────────────────
# Build the message with printf so escapes become REAL newlines (bash does not
# expand \n inside double quotes; jq would then send literal "\n" to Slack).
if [ "$OS_TYPE" = "windows-server" ]; then
  CREDS_BLOCK="$(printf '*User:* `%s`\n*Password:* `%s`\n\n*Connect:*\n```\nssh %s@%s\n```' \
    "$SSH_USER" "$SSH_PASS" "$SSH_USER" "$IP")"
else
  CREDS_BLOCK="$(printf '*User:* `%s`\n\n*SSH private key* — copy everything between the lines into a file `key.pem`, then `chmod 600 key.pem`:\n```\n%s```\n*Connect:*\n```\nssh -i key.pem %s@%s\n```' \
    "$SSH_USER" "$SSH_KEY_CONTENT" "$SSH_USER" "$IP")"
fi

MSG="$(printf ':white_check_mark: *Your VM is ready!*\n\n*Name:* `%s`\n*OS:* %s\n*IP:* `%s`\n\n%s' \
  "$VM_NAME" "$OS_TYPE" "$IP" "$CREDS_BLOCK")"

# Also upload the private key as a downloadable .pem file (best effort).
if [ "$OS_TYPE" != "windows-server" ] && [ -n "$SSH_KEY_CONTENT" ]; then
  IM_CHANNEL="$(curl -sf -X POST "https://slack.com/api/conversations.open" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$SLACK_USER_ID" '{users: $u}')" | jq -r '.channel.id // empty' 2>/dev/null || true)"
  if [ -n "$IM_CHANNEL" ]; then
    KEY_BYTES="$(printf '%s' "$SSH_KEY_CONTENT" | wc -c)"
    UP_JSON="$(curl -sf -X POST "https://slack.com/api/files.getUploadURLExternal" \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
      --data-urlencode "filename=${VM_NAME}-key.pem" --data-urlencode "length=${KEY_BYTES}" 2>/dev/null || true)"
    UP_URL="$(echo "$UP_JSON" | jq -r '.upload_url // empty' 2>/dev/null)"
    FILE_ID="$(echo "$UP_JSON" | jq -r '.file_id // empty' 2>/dev/null)"
    if [ -n "$UP_URL" ] && [ -n "$FILE_ID" ]; then
      printf '%s' "$SSH_KEY_CONTENT" | curl -sf -X POST "$UP_URL" --data-binary @- >/dev/null 2>&1 || true
      curl -sf -X POST "https://slack.com/api/files.completeUploadExternal" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" -H "Content-Type: application/json" \
        -d "$(jq -n --arg ch "$IM_CHANNEL" --arg id "$FILE_ID" --arg t "${VM_NAME}-key.pem" \
          '{channel_id: $ch, files: [{id: $id, title: $t}]}')" >/dev/null 2>&1 || true
    fi
  fi
fi

curl -sf -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$(jq -n --arg ch "$SLACK_USER_ID" --arg txt "$MSG" '{channel: $ch, text: $txt, mrkdwn: true}')"

echo ">> Done. Notified Slack user $SLACK_USER_ID."
