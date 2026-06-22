# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Self-service **VM and LXC container** provisioning on a **local Proxmox VE** host,
driven from Slack. A user runs a slash command; a serverless function triggers a
GitHub Actions workflow; a self-hosted runner *on the Proxmox host* clones a VM
template (`qm`) or creates a container from a `pveam` template (`pct`), enables
SSH, and DMs the credentials back to the user.

`/create-vm` opens **one modal** with a **Resource type** toggle (VM / Container).
Containers use `pct`/`pveam` (no QEMU guest agent — `pct exec` reaches the guest
directly), log in as `root`, and have an extra "unprivileged" option. VMs are
unchanged (`qm clone` of a cloud-init template). `/delete-vm` and `/list-vms`
operate on **both** kinds.

There is **no Terraform/Terragrunt and no nginx reverse proxy** in the current
design (an earlier iteration had both — ignore any stale references). VMs get a
DHCP address on the LAN bridge and are reached over SSH directly. Web routing,
dedicated public IPs, and FortiGate integration are **out of scope**.

## Request flow (read this first)

```
Slack /create-vm amazon-linux my-box
  │  POST (form-encoded, Slack-signed)
  ▼
API Gateway (HTTP API)  →  AWS Lambda  (lambda/index.js)
  │  verifies Slack signature, then GitHub API workflow_dispatch
  ▼
GitHub Actions  (.github/workflows/create-vm.yml)  runs-on: self-hosted
  │
  ▼
Self-hosted runner ON the Proxmox host  →  scripts/create-vm.sh
  │  qm clone / qm set / qm guest exec
  ▼
VM boots, gets DHCP IP
  │
  └─ scripts notify Slack via chat.postMessage  →  DM to the requesting user
```

The crucial architectural point: **Lambda never talks to Proxmox.** Proxmox is on
a private LAN and unreachable from AWS. The only thing that touches Proxmox is the
runner, which lives on the Proxmox host itself and reaches GitHub via outbound
HTTPS. All `qm`/`pvesh` work happens in `scripts/*.sh`.

## Components

- **`lambda/index.js`** — the Slack entrypoint. Zero npm deps (Node 20 built-ins
  `crypto` + `https` only). Verifies the Slack signing secret, then:
  - `/create-vm` (no args) **opens a Slack modal** via `views.open`. The modal has
    a **Resource type** select (`vm`/`ct`) plus name, OS/template dropdown, CPU
    cores, memory GB, disk GB, start-on-boot checkbox, a description note, and (for
    containers) an unprivileged checkbox. The type select has `dispatch_action:
    true`; changing it sends a `block_actions` payload and the handler re-renders
    the modal with `views.update` (`createModal(type, prefill)` — `readPrefill`
    keeps already-typed values across the switch). The **submission** arrives as a
    `view_submission` to the *same* endpoint; `handleViewSubmission` validates and
    dispatches **`create-vm.yml`** (type `vm`) or **`create-container.yml`** (type
    `ct`). Needs `SLACK_BOT_TOKEN` in the Lambda env **and** Slack **Interactivity**
    enabled (Request URL = the API Gateway endpoint).
  - `/delete-vm <name>`, `/list-vms` — plain text slash commands (both cover VMs
    and containers).
- **`.github/workflows/create-vm.yml|create-container.yml|delete-vm.yml|list-vms.yml`**
  — one workflow per action, all `runs-on: self-hosted`, each `workflow_dispatch`
  with typed inputs. They `chmod +x` and run the matching script, and post a Slack
  failure DM on `if: failure()`.
- **`.github/workflows/build-ubuntu-template.yml`** — one-off tool to build the
  **Ubuntu Server VM** template from the official Ubuntu cloud image. Simpler than
  AL2023: the image DHCPs out of the box and libguestfs recognises Ubuntu, so it
  `--install qemu-guest-agent` directly. Defaults `new_id` 9102; point
  `PROXMOX_UBUNTU_TEMPLATE_ID` at it after.
- **`.github/workflows/build-template.yml`** — one-off tool to (re)build an OS
  template: full-clones a pristine base (`src_id`, default `9001`) to a new VMID
  (`new_id`, default `9101`) and offline-customises it with libguestfs
  `virt-customize` (see "Proxmox host facts"). `src_id` must differ from `new_id`
  (the target is destroyed/recreated). Run on the self-hosted runner.
- **`scripts/*.sh`** — run on the Proxmox host. This is where all Proxmox logic
  lives. They are the source of truth for provisioning behavior.

## Non-obvious behavior — don't break these

- **OS → template/user mapping** lives in `scripts/create-vm.sh` (VMs) and the
  template → `pveam` pattern map in `scripts/create-container.sh` (containers). VM
  types: `ubuntu` (user `ubuntu`), `amazon-linux` (user `ec2-user`),
  `windows-server` (user `Administrator`). Container templates: `ubuntu-22.04`
  (user `root`). The allowlists are duplicated in `lambda/index.js` (`VALID_VM_OS`
  / `VALID_CT_TEMPLATES`) — keep them in sync with the scripts and the workflow
  `choice` options.
- **Containers don't use the guest agent.** `pct exec` reaches the guest directly;
  IP discovery polls `pct exec <id> -- ip -4 -o addr show dev eth0` (~2 min window,
  faster boot than VMs). Templates are downloaded on first use via `pveam download`
  (idempotent — skipped if already present). SSH is key-based **root** login (works
  under Ubuntu's default `PermitRootLogin prohibit-password`); the script also
  best-effort installs/enables `sshd` in case the template lacks it.
- **Container DHCP needs RequestBroadcast** — same root cause as the AL2023 VM fix.
  This network's DHCP server replies **unicast** and the nested-ESXi vSwitch (not
  promiscuous) drops unicast frames to the container's veth MAC, so the PVE-written
  `eth0.network` (systemd-networkd, plain `DHCP=ipv4`) never gets a lease. After
  `pct start`, `create-container.sh` writes a drop-in
  `/etc/systemd/network/eth0.network.d/10-request-broadcast.conf` with `[DHCPv4]
  RequestBroadcast=yes` and restarts networkd (verified: lease in ~5s vs never).
  Without it the container provisions, gets no IP, and rolls back. VMs are fine —
  the AL2023/Ubuntu **templates** bake the broadcast fix in; **containers can't**
  (template is a stock tarball), so it's applied live at create time.
- **The `note` (description) field is shell-interpolated** into the workflow via
  `${{ inputs.note }}`, so `lambda/index.js` `sanitizeNote()` strips it to
  `[A-Za-z0-9 _.,:/()-]` (max 100 chars) before dispatch. Don't loosen this without
  re-checking the injection path. All other create inputs are allowlisted/numeric.
- **Linux vs Windows auth differ.** Linux: generate an ephemeral ed25519 keypair,
  inject the public key via cloud-init (`qm set --sshkeys`), DM the **private key**
  once (never stored). Windows: set the Administrator password via
  `qm guest exec ... powershell` and ensure OpenSSH Server is running; DM the
  password.
- **Ownership metadata is stored in the VM/CT description** as JSON
  (`{"slack_user_id":...,"os_type":...,"created_at":...,"kind":"vm|ct","note":...}`)
  plus a `proxmox-cloud` tag. `kind` lets `delete-vm.sh`/`list-vms.sh` know whether
  to use `qm` or `pct`; `note` is the optional user description. `delete-vm.sh`
  enforces that only the creator can delete; `list-vms.sh` filters by this. If you
  change the JSON shape, update **all four** scripts (`create-vm.sh`,
  `create-container.sh`, `list-vms.sh`, `delete-vm.sh`). **Proxmox percent-encodes
  the description** in `qm`/`pct config` output (`:` → `%3A`), so the scripts
  `urllib.parse.unquote` it before `json.loads` — without that the owner parses
  empty and ownership checks silently fail.
- **IP discovery** polls the QEMU guest agent
  (`qm guest cmd <id> network-get-interfaces`) for up to ~7 min (`MAX_WAIT=420`).
  The template MUST have the guest agent **running** (see template build) or
  provisioning hangs then rolls back.
- **Slack message text must use real newlines**, built with `printf` — bash does
  NOT expand `\n` in double quotes, and `jq --arg` would then send literal `\n` to
  Slack (renders as text). The SSH key is sent in a code block and also uploaded
  as a downloadable `<name>-key.pem` (needs the bot `files:write` scope).
- **VM name validation** is a strict regex (`^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$`)
  in both `lambda/index.js` and implied by the scripts. Treat all Slack input as
  untrusted.
- **Slack signature failures return HTTP 200** with an error message in the body,
  not 401 — Slack renders any non-200 as "app did not respond", which hides the
  real cause. Keep this convention.
- **API Gateway / Function URL may base64-encode the request body.** `index.js`
  checks `event.isBase64Encoded` and decodes before computing the HMAC. If you skip
  this, signature verification fails intermittently. The HMAC is computed on the
  raw body, so it must be the exact bytes Slack signed.

## Secrets — where each one lives

Two separate stores; do not mix them up.

- **Lambda environment variables** (the Slack-facing half):
  `SLACK_SIGNING_SECRET`, `SLACK_BOT_TOKEN` (xoxb-…, needed for the `/create-vm`
  modal `views.open`; `files:write` scope to also upload the key file),
  `GITHUB_TOKEN`, `GITHUB_OWNER`, `GITHUB_REPO`. The `GITHUB_TOKEN` MUST be able to
  dispatch workflows — use a **classic PAT with `repo` + `workflow`**; a
  fine-grained PAT without `actions: write` returns `403 Resource not accessible`
  and the Slack reply is the generic "something went wrong".
- **GitHub Actions repo secrets** (the Proxmox-facing half): `SLACK_BOT_TOKEN`
  (used by scripts to DM users), `PROXMOX_NODE`, `PROXMOX_STORAGE`, and one
  template-ID secret per VM OS: `PROXMOX_UBUNTU_TEMPLATE_ID`,
  `PROXMOX_AMAZON_LINUX_TEMPLATE_ID`, `PROXMOX_WINDOWS_TEMPLATE_ID`. Optional:
  `PROXMOX_CT_TEMPLATE_STORAGE` (where `vztmpl` LXC images live, default `local`)
  and `PROXMOX_BRIDGE` (network bridge, default `vmbr0`). Containers need no
  template-ID secret — the image is pulled via `pveam` on demand.

Never print secrets to workflow logs. `.gitignore` already excludes `lambda/.env`,
`*.pem`, `*.key`, and the build zip.

## Deploying the Lambda

From `lambda/`. Note this repo is developed on **Windows** — `zip` is not
available in the bundled Git Bash, so package with PowerShell:

```bash
cd lambda
powershell.exe -Command "Compress-Archive -Path index.js -DestinationPath function.zip -Force"
aws lambda update-function-code --function-name proxmox-cloud-bot \
  --zip-file fileb://function.zip --region us-east-1
rm function.zip
```

`deploy.sh` does first-time creation (function + Function URL + public-invoke
permission). For first deploy it needs `LAMBDA_ROLE_ARN`.

**This AWS account blocks public Lambda Function URLs** (a restriction on
new/limited accounts — `lambda:InvokeFunctionUrl` for an anonymous principal
returns `403 AccessDeniedException` no matter how the URL/permission is set, and
the account concurrency cap is 10). So the Slack entrypoint is an **API Gateway
HTTP API** in front of the Lambda instead of a Function URL:

- Endpoint (set as the Slack slash-command Request URL for all three commands):
  `https://dkfq87mila.execute-api.us-east-1.amazonaws.com`
- It's an HTTP API (`api-id dkfq87mila`) with payload format **2.0** (same event
  shape the handler already expects), a `$default` route/stage (auto-deploy), and
  an `apigw-invoke` resource-based permission on the Lambda
  (`principal apigateway.amazonaws.com`). The handler is unchanged.
- Recreate if needed: `aws apigatewayv2 create-api --name proxmox-cloud-bot-api
  --protocol-type HTTP --target <lambda-arn>` then add the
  `lambda:InvokeFunction` permission for `apigateway.amazonaws.com` with
  source-arn `arn:aws:execute-api:us-east-1:<acct>:<api-id>/*/*` (quick-create
  does NOT add it on this account).

## Environment gotchas (this dev machine)

- **Git Bash mangles absolute paths starting with `/`.** A CloudWatch log group
  like `/aws/lambda/proxmox-cloud-bot` gets rewritten to
  `C:/Program Files/Git/aws/...` and the AWS CLI rejects it. Work around by reading
  logs through Python **boto3** instead of the CLI, or assign the name to a shell
  variable first.
- **No `sshpass`/`expect`.** SSH to the Proxmox host is done from Python **paramiko**
  (password auth). Decode remote output as UTF-8 with `errors="replace"`.
- **Avoid Unicode in Python `print`.** Stdout is cp1252 here; emoji/✓ characters
  raise `UnicodeEncodeError`. Print plain ASCII (`SET`/`MISSING`, not ✅/❌).

## Proxmox host facts

- The self-hosted runner is installed at **`/opt/actions-runner`** on the PVE host
  and runs as a systemd service
  (`actions.runner.iam-adnan-proxmox-cloud.proxmox-pve`). It runs **as root**
  (registered with `RUNNER_ALLOW_RUNASROOT=1`) because `qm` requires root.
- Host needs `jq`, `python3`, `openssl`, and `libguestfs-tools` (for
  `virt-customize` in build-template) installed. Installing libguestfs needs the
  enterprise PVE/Ceph apt repos (which 401 without a subscription) temporarily
  disabled.
- Storage: `local` (dir, ISOs/cloud-init/snippets) and `local-lvm` (lvmthin, VM
  disks). Default bridge `vmbr0`. The thin pool is small (~20 GB) — full clones of
  a 25 GB template are thin (~1.7 GB actual) but watch the cap.
- **The PVE host is itself a VM nested inside VMware ESXi** (`systemd-detect-virt`
  = vmware, vmxnet3 NIC). Inner VMs only get LAN/DHCP if the ESXi vSwitch/port
  group security for the PVE VM's adapter is **Promiscuous Mode + MAC Address
  Changes + Forged Transmits = Accept**. If those reset to default (Reject), every
  VM stops getting an IP (DHCP DISCOVERs leave the guest but are dropped by ESXi).
- **DHCP** must be served on the `vmbr0` segment (192.168.10.0/23, gateway/DHCP at
  .2). `ip=dhcp` relies on it.

### Templates — active VMID is **9101** (`PROXMOX_AMAZON_LINUX_TEMPLATE_ID`)

`9001` is the **pristine base** (download cloud image → `qm create` → `importdisk`
→ `scsi0` → `--ide2 cloudinit` → `qm template`). `9101` is built from `9001` by
`build-template.yml`, which offline-`virt-customize`s the clone with three fixes
the stock Amazon Linux 2023 cloud image needs to actually work on Proxmox — keep
all three when rebuilding or adding an OS:
1. **qemu-guest-agent**: AL2023 ships none and can't use EPEL; install the EL9
   build from the **AlmaLinux 9 AppStream** repo (it installs and runs on AL2023).
2. **DHCP**: write `/etc/systemd/network/05-pve-dhcp.network` with `[Match]
   Type=ether` + `[DHCPv4] RequestBroadcast=yes`. The image uses systemd-networkd;
   it won't latch the unicast DHCP offer without `RequestBroadcast`, and
   `Type=ether` matches whether the NIC is named `eth0` or `ens18`.
3. **No first-boot reboot**: write `/etc/cloud/cloud.cfg.d/99-pve-no-selinux-reboot.cfg`
   = `selinux:\n  selinux_no_reboot: true`. Otherwise AL2023 `cc_selinux` runs a
   `power_state: reboot` ~2 min into first boot of every clone; on Proxmox that
   makes the QEMU process exit and the VM stays **stopped** (user gets working
   creds for an off VM).

## When extending

- **Adding a VM OS type** requires: `VALID_VM_OS` + `VM_OS_LABELS` (modal dropdown)
  in `lambda/index.js`, the `case` block in `scripts/create-vm.sh` (template ID +
  SSH user + auth method), a `choice` option in `create-vm.yml`, a new
  `PROXMOX_*_TEMPLATE_ID` GitHub secret, and a built template on the host (Ubuntu
  via `build-ubuntu-template.yml`; AL2023 via `build-template.yml` with the three
  fixes above).
- **Adding a container template** requires: `VALID_CT_TEMPLATES` +
  `CT_TEMPLATE_LABELS` in `lambda/index.js`, a `choice` option in
  `create-container.yml`, and a `case` entry mapping the friendly id to a `pveam`
  catalog pattern in `scripts/create-container.sh`. No template-ID secret — the
  image is downloaded on demand.
- **Changing the create form** (fields, validation) is done in `createModal()` +
  `handleViewSubmission` (+ `readPrefill` if the value should survive a type
  switch) in `lambda/index.js`; new fields must be threaded through both
  `create-vm.yml`/`create-container.yml` inputs → the matching script's args (e.g.
  `cores`, `onboot`, `note`). Free-text fields must be sanitized (see
  `sanitizeNote`) — workflow inputs are shell-interpolated.
- **Adding a command** requires a new workflow file, a new script, and a new
  handler branch in `lambda/index.js` (plus a Slack slash command pointed at the
  API Gateway endpoint).
- Keep provisioning logic in the scripts, not the workflows — the workflows are
  thin wrappers.
