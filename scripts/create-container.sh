#!/bin/bash
# Runs on the Proxmox host via self-hosted GitHub Actions runner.
# Creates an LXC container with `pct` (containers do NOT use the QEMU guest
# agent — `pct exec` talks to the container directly).
# Usage: create-container.sh <template> <hostname> <slack_user_id> \
#          [cores] [memory_mb] [disk_gb] [unprivileged] [onboot] [note]
set -euo pipefail

TEMPLATE="$1"          # friendly id, e.g. ubuntu-22.04
HOSTNAME="$2"
SLACK_USER_ID="$3"
CORES="${4:-2}"
MEMORY_MB="${5:-2048}"
DISK_GB="${6:-8}"
UNPRIVILEGED="${7:-1}"
ONBOOT="${8:-0}"
NOTE="${9:-}"

STORAGE="${PROXMOX_STORAGE:-local-lvm}"               # rootfs storage (lvmthin/dir/zfs)
TEMPLATE_STORAGE="${PROXMOX_CT_TEMPLATE_STORAGE:-local}" # where vztmpl images live
NODE="${PROXMOX_NODE:-pve}"
BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"

SSH_USER="root" # LXC containers log in as root; cloud-init's ciuser doesn't apply

# ── Resolve friendly template -> pveam catalog name pattern ──────────────────
case "$TEMPLATE" in
  ubuntu-22.04) TMPL_PATTERN="ubuntu-22.04-standard" ;;
  *)
    echo "ERROR: Unknown container template: $TEMPLATE" >&2
    exit 1
    ;;
esac

# ── Ensure the template image is present (download once, idempotent) ─────────
pveam update >/dev/null 2>&1 || true
TMPL_NAME="$(pveam available --section system 2>/dev/null \
  | awk '{print $2}' | grep "^${TMPL_PATTERN}" | sort -V | tail -1 || true)"
if [ -z "$TMPL_NAME" ]; then
  echo "ERROR: template matching '$TMPL_PATTERN' not found in pveam catalog." >&2
  exit 1
fi

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TMPL_NAME"; then
  echo ">> Downloading container template $TMPL_NAME to $TEMPLATE_STORAGE ..."
  pveam download "$TEMPLATE_STORAGE" "$TMPL_NAME"
fi
TMPL_VOLID="${TEMPLATE_STORAGE}:vztmpl/${TMPL_NAME}"

# ── Get next available VMID ───────────────────────────────────────────────────
VMID=$(pvesh get /cluster/nextid)
echo ">> Creating container '$HOSTNAME' (CTID=$VMID, template=$TMPL_NAME, cores=$CORES, mem=${MEMORY_MB}MB, disk=${DISK_GB}G, unprivileged=$UNPRIVILEGED)"

# ── Generate an ephemeral SSH key (public key injected; private key DM'd once) ─
KEY_DIR="$(mktemp -d /tmp/ct-key-XXXXXX)"
KEY_FILE="${KEY_DIR}/id_ed25519"
trap "rm -rf ${KEY_DIR}" EXIT
ssh-keygen -t ed25519 -f "$KEY_FILE" -C "proxmox-cloud@${HOSTNAME}" -N "" -q

# Random password (alphanumeric, 20 chars) for root — usable for the Proxmox
# console and, with password SSH enabled below, for SSH too (alongside the key).
SSH_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"

# ── Create the container ──────────────────────────────────────────────────────
# nesting=1 keeps common workloads (docker, systemd quirks) happy; harmless otherwise.
pct create "$VMID" "$TMPL_VOLID" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY_MB" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged "$UNPRIVILEGED" \
  --onboot "$ONBOOT" \
  --features nesting=1 \
  --ssh-public-keys "${KEY_FILE}.pub"

SSH_KEY_CONTENT="$(cat "$KEY_FILE")"

# Owner metadata (shared shape with create-vm.sh / list-vms.sh / delete-vm.sh).
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
pct set "$VMID" \
  --description "{\"slack_user_id\":\"$SLACK_USER_ID\",\"os_type\":\"$TEMPLATE\",\"created_at\":\"$CREATED_AT\",\"kind\":\"ct\",\"note\":\"$NOTE\"}" \
  --tags "proxmox-cloud"

# ── Start container ───────────────────────────────────────────────────────────
pct start "$VMID"
echo ">> Container started — waiting for an IP..."

# ── DHCP broadcast fix (same root cause as the AL2023 VM template) ───────────
# The PVE host is nested in VMware ESXi and this network's DHCP server replies
# UNICAST. ESXi drops unicast frames addressed to the container's veth MAC (the
# vSwitch isn't promiscuous), so systemd-networkd — which the Ubuntu LXC template
# uses, configured by PVE in eth0.network — never latches a lease. Requesting a
# BROADCAST offer fixes it. Apply a drop-in once the container's init is up, then
# restart networkd. Best-effort + guarded so non-networkd templates don't break.
for _ in $(seq 1 15); do
  pct exec "$VMID" -- true 2>/dev/null && break
  sleep 2
done
pct exec "$VMID" -- bash -c '
  if [ -f /etc/systemd/network/eth0.network ] || systemctl is-active --quiet systemd-networkd; then
    mkdir -p /etc/systemd/network/eth0.network.d
    printf "[DHCPv4]\nRequestBroadcast=yes\n" > /etc/systemd/network/eth0.network.d/10-request-broadcast.conf
    systemctl restart systemd-networkd
  fi
' 2>/dev/null || true

# ── Wait for IP (containers boot fast; pct exec works once init is up) ────────
MAX_WAIT=120
ELAPSED=0
IP=""
while [ -z "$IP" ] && [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  IP="$(pct exec "$VMID" -- ip -4 -o addr show dev eth0 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -1 || true)"
done

if [ -z "$IP" ]; then
  echo "ERROR: container did not obtain an IP within ${MAX_WAIT}s." >&2
  pct stop "$VMID" || true
  pct destroy "$VMID" --purge || true
  exit 1
fi

echo ">> Container is reachable at $IP"

# ── Ensure sshd is present and running (best effort) ─────────────────────────
# "standard" templates usually ship openssh-server; install if missing. Key-based
# root login works under the default PermitRootLogin=prohibit-password.
pct exec "$VMID" -- bash -c '
  command -v sshd >/dev/null 2>&1 || command -v /usr/sbin/sshd >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y openssh-server
  }
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
' >/dev/null 2>&1 || true

# ── Set root password + enable SSH password auth (and root login) ────────────
# So the password works over SSH alongside the key. A 00- drop-in wins because
# sshd uses the FIRST match. SSH_PASS is alphanumeric, safe to interpolate.
pct exec "$VMID" -- bash -c "echo 'root:${SSH_PASS}' | chpasswd; mkdir -p /etc/ssh/sshd_config.d; printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' > /etc/ssh/sshd_config.d/00-pve-password-auth.conf; systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true" >/dev/null 2>&1 || true

# ── Send Slack DM with credentials ───────────────────────────────────────────
# Build with printf so escapes become REAL newlines (bash does not expand \n in
# double quotes; jq --arg would otherwise send literal "\n" to Slack).
CREDS_BLOCK="$(printf '*User:* `%s`\n*Password:* `%s`  _(works for console and SSH)_\n\n*SSH private key* — copy everything between the lines into a file `key.pem`, then `chmod 600 key.pem`:\n```\n%s```\n*Connect with the key:*\n```\nssh -i key.pem %s@%s\n```\n*Or with the password:*\n```\nssh %s@%s\n```' \
  "$SSH_USER" "$SSH_PASS" "$SSH_KEY_CONTENT" "$SSH_USER" "$IP" "$SSH_USER" "$IP")"

MSG="$(printf ':white_check_mark: *Your container is ready!*\n\n*Name:* `%s`\n*Template:* %s\n*IP:* `%s`\n\n%s' \
  "$HOSTNAME" "$TEMPLATE" "$IP" "$CREDS_BLOCK")"

# Also upload the private key as a downloadable .pem file (best effort).
if [ -n "$SSH_KEY_CONTENT" ]; then
  IM_CHANNEL="$(curl -sf -X POST "https://slack.com/api/conversations.open" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$SLACK_USER_ID" '{users: $u}')" | jq -r '.channel.id // empty' 2>/dev/null || true)"
  if [ -n "$IM_CHANNEL" ]; then
    KEY_BYTES="$(printf '%s' "$SSH_KEY_CONTENT" | wc -c)"
    UP_JSON="$(curl -sf -X POST "https://slack.com/api/files.getUploadURLExternal" \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
      --data-urlencode "filename=${HOSTNAME}-key.pem" --data-urlencode "length=${KEY_BYTES}" 2>/dev/null || true)"
    UP_URL="$(echo "$UP_JSON" | jq -r '.upload_url // empty' 2>/dev/null)"
    FILE_ID="$(echo "$UP_JSON" | jq -r '.file_id // empty' 2>/dev/null)"
    if [ -n "$UP_URL" ] && [ -n "$FILE_ID" ]; then
      printf '%s' "$SSH_KEY_CONTENT" | curl -sf -X POST "$UP_URL" --data-binary @- >/dev/null 2>&1 || true
      curl -sf -X POST "https://slack.com/api/files.completeUploadExternal" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" -H "Content-Type: application/json" \
        -d "$(jq -n --arg ch "$IM_CHANNEL" --arg id "$FILE_ID" --arg t "${HOSTNAME}-key.pem" \
          '{channel_id: $ch, files: [{id: $id, title: $t}]}')" >/dev/null 2>&1 || true
    fi
  fi
fi

curl -sf -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$(jq -n --arg ch "$SLACK_USER_ID" --arg txt "$MSG" '{channel: $ch, text: $txt, mrkdwn: true}')"

echo ">> Done. Notified Slack user $SLACK_USER_ID."
