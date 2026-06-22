#!/bin/bash
# Runs on the Proxmox host via self-hosted GitHub Actions runner.
# Deletes a VM (qm) or container (pct) by name. Only the creator can delete it.
# Usage: delete-vm.sh <name> <slack_user_id>
set -euo pipefail

VM_NAME="$1"
SLACK_USER_ID="$2"

notify() {
  curl -sf -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -n --arg ch "$SLACK_USER_ID" --arg txt "$1" '{channel: $ch, text: $txt}')" || true
}

# ── Collect candidates across VMs and containers ─────────────────────────────
# Names aren't guaranteed unique (and a VM and a container could share a name),
# so match on the config-reported name/hostname and record the kind with the id.
declare -a CAND=()  # entries like "vm:123" / "ct:456"

while IFS= read -r ID; do
  [ -z "$ID" ] && continue
  NM="$(qm config "$ID" 2>/dev/null | sed -n 's/^name: //p')"
  [ "$NM" = "$VM_NAME" ] && CAND+=("vm:$ID")
done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')

while IFS= read -r ID; do
  [ -z "$ID" ] && continue
  NM="$(pct config "$ID" 2>/dev/null | sed -n 's/^hostname: //p')"
  [ "$NM" = "$VM_NAME" ] && CAND+=("ct:$ID")
done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')

if [ "${#CAND[@]}" -eq 0 ]; then
  notify ":warning: \`${VM_NAME}\` not found."
  exit 0
fi

DELETED=0
for ENTRY in "${CAND[@]}"; do
  KIND="${ENTRY%%:*}"
  VMID="${ENTRY##*:}"

  # ── Verify ownership ───────────────────────────────────────────────────────
  # Proxmox percent-encodes the description in config output; URL-decode first.
  if [ "$KIND" = "vm" ]; then
    DESC="$(qm config "$VMID" | grep '^description:' | sed 's/^description: //' || true)"
  else
    DESC="$(pct config "$VMID" | grep '^description:' | sed 's/^description: //' || true)"
  fi
  OWNER="$(printf '%s' "$DESC" | python3 -c "import json,sys,urllib.parse; d=json.loads(urllib.parse.unquote(sys.stdin.read())); print(d.get('slack_user_id',''))" 2>/dev/null || true)"

  if [ "$OWNER" != "$SLACK_USER_ID" ]; then
    echo ">> Skipping $KIND $VMID (owned by '$OWNER', not '$SLACK_USER_ID')"
    continue
  fi

  echo ">> Deleting $KIND '$VM_NAME' (id=$VMID)..."

  if [ "$KIND" = "vm" ]; then
    STATUS="$(qm status "$VMID" | awk '{print $2}')"
    if [ "$STATUS" = "running" ]; then
      qm stop "$VMID"
      for _ in $(seq 1 30); do
        sleep 2
        [ "$(qm status "$VMID" | awk '{print $2}')" = "stopped" ] && break
      done
    fi
    qm destroy "$VMID" --purge
  else
    STATUS="$(pct status "$VMID" | awk '{print $2}')"
    if [ "$STATUS" = "running" ]; then
      pct stop "$VMID"
      for _ in $(seq 1 30); do
        sleep 2
        [ "$(pct status "$VMID" | awk '{print $2}')" = "stopped" ] && break
      done
    fi
    pct destroy "$VMID" --purge
  fi

  echo ">> $KIND $VM_NAME (id=$VMID) deleted."
  DELETED=$((DELETED + 1))
done

if [ "$DELETED" -eq 0 ]; then
  notify ":x: You don't have permission to delete \`${VM_NAME}\`. Only its owner can delete it."
  exit 0
fi

notify ":wastebasket: \`${VM_NAME}\` has been deleted."
