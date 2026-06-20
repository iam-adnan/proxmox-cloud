#!/bin/bash
# Runs on the Proxmox host via self-hosted GitHub Actions runner.
# Usage: create-vm.sh <os_type> <vm_name> <slack_user_id>
set -euo pipefail

OS_TYPE="$1"
VM_NAME="$2"
SLACK_USER_ID="$3"

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
echo ">> Creating VM '$VM_NAME' (VMID=$VMID, OS=$OS_TYPE, template=$TEMPLATE_ID)"

# ── Clone template ────────────────────────────────────────────────────────────
qm clone "$TEMPLATE_ID" "$VMID" \
  --name "$VM_NAME" \
  --full \
  --storage "$STORAGE"

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

  # Stock cloud images (notably Amazon Linux 2023) ship without
  # qemu-guest-agent, which IP discovery below depends on. Inject a cloud-init
  # *vendor-data* snippet that installs and starts it on first boot. vendor-data
  # is additive — it does NOT override the user/ssh/network data set above.
  SNIPPET_STORAGE="${PROXMOX_SNIPPET_STORAGE:-local}"
  SNIPPET_REL="snippets/proxmox-cloud-qga.yaml"

  STORE_PATH="$(pvesh get "/storage/${SNIPPET_STORAGE}" --output-format json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('path',''))" 2>/dev/null || true)"
  CONTENT="$(pvesh get "/storage/${SNIPPET_STORAGE}" --output-format json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('content',''))" 2>/dev/null || true)"

  if [ -n "$STORE_PATH" ]; then
    # Enable the 'snippets' content type if it isn't already (idempotent).
    case ",${CONTENT}," in
      *,snippets,*) ;;
      *) pvesm set "${SNIPPET_STORAGE}" --content "${CONTENT:+${CONTENT},}snippets" ;;
    esac

    mkdir -p "${STORE_PATH}/snippets"
    cat > "${STORE_PATH}/snippets/proxmox-cloud-qga.yaml" <<'YAML'
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
YAML

    qm set "$VMID" --cicustom "vendor=${SNIPPET_STORAGE}:${SNIPPET_REL}"
  else
    echo "WARN: storage '${SNIPPET_STORAGE}' not found; skipping guest-agent auto-install." >&2
  fi

  SSH_KEY_CONTENT="$(cat "$KEY_FILE")"
fi

# ── Start VM ─────────────────────────────────────────────────────────────────
qm start "$VMID"
echo ">> VM started — waiting for guest agent to report an IP..."

# ── Wait for IP via QEMU guest agent ─────────────────────────────────────────
# Allow time for cloud-init to install + start the agent on first boot.
MAX_WAIT=420
ELAPSED=0
IP=""

while [ -z "$IP" ] && [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  sleep 10
  ELAPSED=$((ELAPSED + 10))

  RAW="$(qm guest cmd "$VMID" network-get-interfaces 2>&1 || true)"
  echo "DIAG[t=${ELAPSED}s] raw guest agent output: ${RAW}"

  IP="$(printf '%s' "$RAW" | \
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
  echo "DIAG ==== qm config ===="; qm config "$VMID" || true
  echo "DIAG ==== qm status ===="; qm status "$VMID" || true
  echo "DIAG ==== qm agent ping ===="; if qm agent "$VMID" ping; then echo "DIAG ping OK"; else echo "DIAG ping FAILED"; fi
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
if [ "$OS_TYPE" = "windows-server" ]; then
  CREDS_BLOCK="*User:* \`${SSH_USER}\`\n*Password:* \`${SSH_PASS}\`\n\n*Connect:*\n\`\`\`ssh ${SSH_USER}@${IP}\`\`\`"
else
  CREDS_BLOCK="*User:* \`${SSH_USER}\`\n\n*SSH Private Key* (save this — it won't be shown again):\n\`\`\`\n${SSH_KEY_CONTENT}\n\`\`\`\n\n*Connect:*\n\`\`\`ssh -i key.pem ${SSH_USER}@${IP}\`\`\`"
fi

MSG=":white_check_mark: *Your VM is ready!*\n\n*Name:* \`${VM_NAME}\`\n*OS:* ${OS_TYPE}\n*IP:* \`${IP}\`\n\n${CREDS_BLOCK}"

curl -sf -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg ch "$SLACK_USER_ID" --arg txt "$MSG" '{channel: $ch, text: $txt, mrkdwn: true}')"

echo ">> Done. Notified Slack user $SLACK_USER_ID."
