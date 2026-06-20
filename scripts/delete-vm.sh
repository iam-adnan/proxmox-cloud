#!/bin/bash
# Runs on the Proxmox host via self-hosted GitHub Actions runner.
# Usage: delete-vm.sh <vm_name> <slack_user_id>
# Only the user who created the VM can delete it.
set -euo pipefail

VM_NAME="$1"
SLACK_USER_ID="$2"

notify() {
  curl -sf -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -n --arg ch "$SLACK_USER_ID" --arg txt "$1" '{channel: $ch, text: $txt}')" || true
}

# ── Find VMID(s) by name ──────────────────────────────────────────────────────
# A name is not guaranteed unique (create-vm doesn't enforce it), so collect all
# matches and operate on each one this user owns.
mapfile -t VMIDS < <(qm list | awk -v name="$VM_NAME" 'NR>1 && $2==name {print $1}')

if [ "${#VMIDS[@]}" -eq 0 ]; then
  notify ":warning: VM \`${VM_NAME}\` not found."
  exit 0
fi

DELETED=0
for VMID in "${VMIDS[@]}"; do
  # ── Verify ownership ───────────────────────────────────────────────────────
  DESC="$(qm config "$VMID" | grep '^description:' | sed 's/^description: //' || true)"
  OWNER="$(echo "$DESC" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('slack_user_id',''))" 2>/dev/null || true)"

  if [ "$OWNER" != "$SLACK_USER_ID" ]; then
    echo ">> Skipping VMID=$VMID (owned by '$OWNER', not '$SLACK_USER_ID')"
    continue
  fi

  echo ">> Deleting VM '$VM_NAME' (VMID=$VMID)..."

  # ── Stop VM if running ─────────────────────────────────────────────────────
  STATUS="$(qm status "$VMID" | awk '{print $2}')"
  if [ "$STATUS" = "running" ]; then
    qm stop "$VMID"
    for _ in $(seq 1 30); do
      sleep 2
      [ "$(qm status "$VMID" | awk '{print $2}')" = "stopped" ] && break
    done
  fi

  # ── Destroy VM ─────────────────────────────────────────────────────────────
  qm destroy "$VMID" --purge
  echo ">> VM $VM_NAME (VMID=$VMID) deleted."
  DELETED=$((DELETED + 1))
done

if [ "$DELETED" -eq 0 ]; then
  notify ":x: You don't have permission to delete \`${VM_NAME}\`. Only its owner can delete it."
  exit 0
fi

# ── Notify Slack ──────────────────────────────────────────────────────────────
notify ":wastebasket: VM \`${VM_NAME}\` has been deleted."
