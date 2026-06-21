# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Self-service VM provisioning on a **local Proxmox VE** host, driven from Slack. A
user runs a slash command; a serverless function triggers a GitHub Actions
workflow; a self-hosted runner *on the Proxmox host* clones a VM template, enables
SSH, and DMs the credentials back to the user.

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
  `crypto` + `https` only). Verifies the Slack signing secret, parses the command,
  validates input, and calls `workflow_dispatch`. Handles `/create-vm`,
  `/delete-vm`, `/list-vms`.
- **`.github/workflows/*.yml`** — one workflow per command, all `runs-on:
  self-hosted`, each `workflow_dispatch` with typed inputs. They `chmod +x` and run
  the matching script, and post a Slack failure DM on `if: failure()`.
- **`scripts/*.sh`** — run on the Proxmox host. This is where all Proxmox logic
  lives. They are the source of truth for provisioning behavior.

## Non-obvious behavior — don't break these

- **OS → template/user mapping** lives in `scripts/create-vm.sh`. Three types:
  `ubuntu` (user `ubuntu`), `amazon-linux` (user `ec2-user`), `windows-server`
  (user `Administrator`). The valid-OS list is duplicated in `lambda/index.js`
  (`VALID_OS`) — keep both in sync.
- **Linux vs Windows auth differ.** Linux: generate an ephemeral ed25519 keypair,
  inject the public key via cloud-init (`qm set --sshkeys`), DM the **private key**
  once (never stored). Windows: set the Administrator password via
  `qm guest exec ... powershell` and ensure OpenSSH Server is running; DM the
  password.
- **Ownership metadata is stored in the VM description** as JSON
  (`{"slack_user_id":...,"os_type":...,"created_at":...}`) plus a `proxmox-cloud`
  tag. `delete-vm.sh` enforces that only the creator can delete; `list-vms.sh`
  filters by this. If you change the JSON shape, update all three scripts.
- **IP discovery** polls the QEMU guest agent
  (`qm guest cmd <id> network-get-interfaces`) for up to 5 min. The VM template
  MUST have the guest agent enabled or provisioning hangs then rolls back.
- **VM name validation** is a strict regex (`^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$`)
  in both `lambda/index.js` and implied by the scripts. Treat all Slack input as
  untrusted.
- **Slack signature failures return HTTP 200** with an error message in the body,
  not 401 — Slack renders any non-200 as "app did not respond", which hides the
  real cause. Keep this convention.
- **Lambda Function URL may base64-encode the request body.** `index.js` checks
  `event.isBase64Encoded` and decodes before computing the HMAC. If you skip this,
  signature verification fails intermittently.

## Secrets — where each one lives

Two separate stores; do not mix them up.

- **Lambda environment variables** (the Slack-facing half):
  `SLACK_SIGNING_SECRET`, `GITHUB_TOKEN` (PAT needs the `workflow` scope to
  dispatch), `GITHUB_OWNER`, `GITHUB_REPO`.
- **GitHub Actions repo secrets** (the Proxmox-facing half): `SLACK_BOT_TOKEN`
  (used by scripts to DM users), `PROXMOX_NODE`, `PROXMOX_STORAGE`, and one
  template-ID secret per OS: `PROXMOX_UBUNTU_TEMPLATE_ID`,
  `PROXMOX_AMAZON_LINUX_TEMPLATE_ID`, `PROXMOX_WINDOWS_TEMPLATE_ID`.

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
- Host needs `jq`, `python3`, and `openssl` installed (scripts depend on them).
- Storage: `local` (dir, ISOs/cloud-init) and `local-lvm` (lvmthin, VM disks).
  Default bridge `vmbr0`. Templates are cloud-init-enabled with the guest agent on.
- Templates are built by: download cloud image → `qm create` → `qm importdisk` →
  attach as `scsi0` → add `--ide2 <storage>:cloudinit` → `qm template`. The
  Amazon Linux 2023 template is VMID **9001**.

## When extending

- **Adding an OS type** requires three coordinated edits: `VALID_OS` in
  `lambda/index.js`, the `case` block in `scripts/create-vm.sh` (template ID + SSH
  user + auth method), and a new `PROXMOX_*_TEMPLATE_ID` GitHub secret + a built
  template on the host.
- **Adding a command** requires a new workflow file, a new script, and a new
  `app.command`/handler branch in `lambda/index.js` (plus a Slack slash command
  pointed at the Function URL).
- Keep provisioning logic in the scripts, not the workflows — the workflows are
  thin wrappers.
