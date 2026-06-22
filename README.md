# proxmox-cloud

Self-service **VM and container** provisioning via Slack. Users request resources
through a slash command; a GitHub Actions CI/CD pipeline (running on a self-hosted
runner on the Proxmox host) creates the VM (`qm`) or LXC container (`pct`), enables
SSH, and DMs credentials back to the user.

## Supported resources

**Virtual machines** (`qm` clone of a cloud-init template):

| Form option | OS | Default SSH user | Auth method |
|---|---|---|---|
| Ubuntu Server | Ubuntu Server (cloud image) | `ubuntu` | SSH key (ed25519) **+ password** |
| Amazon Linux 2023 | Amazon Linux 2023 | `ec2-user` | SSH key (ed25519) **+ password** |
| Windows Server | Windows Server | `Administrator` | Password |

**Containers** (`pct` from a `pveam` template):

| Form option | Template | Default SSH user | Auth method |
|---|---|---|---|
| Ubuntu 22.04 | `ubuntu-22.04-standard` LXC | `root` | SSH key (ed25519) **+ password** |

Linux VMs and containers get **both** an ephemeral SSH key *and* a random
password (DM'd together). The password works for the Proxmox console, `sudo`, and
SSH (password auth is enabled). The key is shown once and never stored.

## Slack commands

```
/create-vm          # opens a form: Resource type (VM / Container), name, OS/template,
                    # CPU cores, memory, disk, start-on-boot, description, and
                    # (containers) an unprivileged toggle

/delete-vm my-dev-box   # works for both VMs and containers

/list-vms               # lists your VMs and containers
```

`/create-vm` opens a modal. Choosing **Resource type** re-renders the form so VM and
container fields differ. On submit you get an ephemeral acknowledgement; when the
resource is ready (containers ~1–2 min, VMs 2–5 min) the bot DMs you the IP and
credentials. Only the user who created a resource can delete it.

---

## Architecture

```
Slack slash command
  │  (Socket Mode — no public URL required)
  ▼
Slack Bot  (Node.js / @slack/bolt)
  │  triggers workflow via GitHub API
  ▼
GitHub Actions  (self-hosted runner on Proxmox host)
  │  scripts/create-vm.sh
  ▼
Proxmox VE  →  clone template  →  cloud-init / guest-agent
  │
  └─ DM to Slack user: IP + SSH key / password
```

The runner runs **on the Proxmox host itself**, so `qm`, `pvesh`, and `pvesh` are available natively. No firewall ports need to be opened for GitHub to reach Proxmox.

---

## One-time Proxmox setup

### 1. Create VM templates

Create one template per OS. Templates must have:
- QEMU guest agent installed and enabled (`qm set <id> --agent enabled=1`)
- For Ubuntu / Amazon Linux: cloud-init support (`--ide2 <storage>:cloudinit`)
- For Windows Server: OpenSSH Server pre-installed, VirtIO guest agent installed

Mark each as a template:
```bash
qm template <VMID>
```

Note the VMID for each template — you'll need them as GitHub Secrets.

### 2. Install the GitHub Actions self-hosted runner on Proxmox

On your Proxmox host (as root or a dedicated CI user):

```bash
mkdir -p /opt/github-runner && cd /opt/github-runner
# Download the latest runner from:
# https://github.com/actions/runner/releases
curl -o actions-runner-linux-x64.tar.gz -L <URL>
tar xzf actions-runner-linux-x64.tar.gz

# Register (get the token from: repo → Settings → Actions → Runners → New self-hosted runner)
./config.sh --url https://github.com/iam-adnan/proxmox-cloud --token <RUNNER_TOKEN>

# Install and start as a service
./svc.sh install
./svc.sh start
```

Ensure `jq`, `python3`, and `openssl` are installed:
```bash
apt-get install -y jq python3 openssl
```

---

## GitHub Actions Secrets

Go to **repo → Settings → Secrets and variables → Actions** and add:

| Secret | Description |
|---|---|
| `PROXMOX_NODE` | Proxmox node name (e.g. `pve`) |
| `PROXMOX_STORAGE` | Storage pool for VM disks / container rootfs (e.g. `local-lvm`) |
| `PROXMOX_UBUNTU_TEMPLATE_ID` | VMID of the Ubuntu Server template (build via `build-ubuntu-template.yml`) |
| `PROXMOX_AMAZON_LINUX_TEMPLATE_ID` | VMID of the Amazon Linux template |
| `PROXMOX_WINDOWS_TEMPLATE_ID` | VMID of the Windows Server template |
| `PROXMOX_CT_TEMPLATE_STORAGE` | *(optional)* storage holding `vztmpl` LXC images (default `local`) |
| `PROXMOX_BRIDGE` | *(optional)* network bridge for new resources (default `vmbr0`) |
| `SLACK_BOT_TOKEN` | Slack bot OAuth token (`xoxb-...`) — used by workflows to send DMs |

> **Building templates:** run the `Build Ubuntu Cloud Template` workflow (manual
> dispatch) to create the Ubuntu VM template, then set `PROXMOX_UBUNTU_TEMPLATE_ID`
> to the VMID it prints. Container templates are downloaded automatically via
> `pveam` on first use — no template build needed.

---

## Slack Bot setup

### 1. Create a Slack App

1. Go to https://api.slack.com/apps → **Create New App** → **From scratch**
2. **Socket Mode** → enable it → generate App-Level Token (scope: `connections:write`) → save as `SLACK_APP_TOKEN`
3. **OAuth & Permissions** → Bot Token Scopes: add `commands`, `chat:write`
4. **Slash Commands** → create `/create-vm`, `/delete-vm`, `/list-vms`
5. Install the app to your workspace
6. Copy the **Bot User OAuth Token** (`xoxb-...`) → `SLACK_BOT_TOKEN`
7. Copy the **Signing Secret** → `SLACK_SIGNING_SECRET`

### 2. Configure and run the bot

```bash
cd slack-bot
cp .env.example .env
# Fill in all values in .env

npm install
npm start
```

The bot uses Socket Mode (WebSocket) — no public URL or ngrok needed.

To run persistently:
```bash
npm install -g pm2
pm2 start index.js --name proxmox-cloud-bot
pm2 save && pm2 startup
```

### Bot environment variables

| Variable | Description |
|---|---|
| `SLACK_BOT_TOKEN` | `xoxb-...` bot OAuth token |
| `SLACK_APP_TOKEN` | `xapp-...` app-level token for Socket Mode |
| `SLACK_SIGNING_SECRET` | Slack app signing secret |
| `GITHUB_TOKEN` | GitHub PAT with `repo` + `workflow` scopes |
| `GITHUB_OWNER` | GitHub username or org (e.g. `iam-adnan`) |
| `GITHUB_REPO` | Repository name (`proxmox-cloud`) |

---

## How VM creation works

1. User runs `/create-vm ubuntu my-server`
2. Slack bot validates input and triggers `create-vm` GitHub Actions workflow
3. Self-hosted runner on Proxmox executes `scripts/create-vm.sh`:
   - Clones the appropriate template with `qm clone --full`
   - For Linux: generates ed25519 SSH key pair, injects public key via cloud-init
   - Starts the VM
   - Polls QEMU guest agent every 10 s (up to 5 min) until the VM reports an IPv4 address
   - For Windows: waits for boot, sets Administrator password via guest agent, ensures OpenSSH is running
   - Sends Slack DM with IP + credentials
4. The private SSH key is displayed once in the DM and never stored

VM metadata (owner Slack ID, OS type, creation time) is stored in the Proxmox VM description field as JSON, tagged `proxmox-cloud`. This enables per-user `list-vms` and ownership-enforced `delete-vm`.
