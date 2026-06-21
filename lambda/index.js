/**
 * AWS Lambda handler — Slack entrypoint (behind an API Gateway HTTP API).
 *
 * /create-vm  -> opens a modal (name, OS dropdown, memory, disk) via views.open
 * modal submit (view_submission) -> validates and triggers create-vm.yml
 * /delete-vm <name>, /list-vms -> text slash commands (unchanged)
 *
 * Uses only Node.js built-ins (crypto, https) — no npm install needed.
 */

const crypto = require('crypto');
const https = require('https');

const {
  SLACK_SIGNING_SECRET,
  SLACK_BOT_TOKEN,
  GITHUB_TOKEN,
  GITHUB_OWNER,
  GITHUB_REPO,
} = process.env;

const VALID_OS = ['ubuntu', 'amazon-linux', 'windows-server'];
const OS_LABELS = {
  'amazon-linux': 'Amazon Linux 2023',
  ubuntu: 'Ubuntu Server',
  'windows-server': 'Windows Server',
};
const VM_NAME_RE = /^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$/;
const MEM_MIN_GB = 1, MEM_MAX_GB = 64;
const DISK_MIN_GB = 25, DISK_MAX_GB = 500;

// ── Slack signature verification ─────────────────────────────────────────────
function verifySlackSignature(headers, rawBody) {
  const timestamp = headers['x-slack-request-timestamp'];
  const slackSig = headers['x-slack-signature'];
  if (!timestamp || !slackSig) return false;
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false;

  const hmac = crypto
    .createHmac('sha256', SLACK_SIGNING_SECRET)
    .update(`v0:${timestamp}:${rawBody}`)
    .digest('hex');
  const computed = Buffer.from(`v0=${hmac}`);
  const received = Buffer.from(slackSig);
  if (computed.length !== received.length) return false;
  return crypto.timingSafeEqual(computed, received);
}

// ── GitHub workflow_dispatch ─────────────────────────────────────────────────
function triggerWorkflow(workflowFile, inputs) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify({ ref: 'master', inputs });
    const req = https.request(
      {
        hostname: 'api.github.com',
        path: `/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/workflows/${workflowFile}/dispatches`,
        method: 'POST',
        headers: {
          Authorization: `Bearer ${GITHUB_TOKEN}`,
          Accept: 'application/vnd.github.v3+json',
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
          'User-Agent': 'proxmox-cloud-lambda',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      },
      (res) => {
        if (res.statusCode === 204) return resolve();
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => reject(new Error(`GitHub API ${res.statusCode}: ${body}`)));
      }
    );
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

// ── Slack Web API (bot token) ────────────────────────────────────────────────
function slackApi(method, payload) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(payload);
    const req = https.request(
      {
        hostname: 'slack.com',
        path: `/api/${method}`,
        method: 'POST',
        headers: {
          Authorization: `Bearer ${SLACK_BOT_TOKEN}`,
          'Content-Type': 'application/json; charset=utf-8',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            if (!json.ok) return reject(new Error(`${method}: ${json.error}`));
            resolve(json);
          } catch (e) {
            reject(new Error(`${method}: bad response ${data}`));
          }
        });
      }
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ── Helpers ──────────────────────────────────────────────────────────────────
function ephemeral(text) {
  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ response_type: 'ephemeral', text }),
  };
}
const ok = (obj) => ({
  statusCode: 200,
  headers: { 'Content-Type': 'application/json' },
  body: obj ? JSON.stringify(obj) : '',
});

function createVmModal() {
  const osOptions = VALID_OS.map((v) => ({
    text: { type: 'plain_text', text: OS_LABELS[v] },
    value: v,
  }));
  return {
    type: 'modal',
    callback_id: 'create_vm_modal',
    title: { type: 'plain_text', text: 'Create a VM' },
    submit: { type: 'plain_text', text: 'Create' },
    close: { type: 'plain_text', text: 'Cancel' },
    blocks: [
      {
        type: 'input',
        block_id: 'vm_name',
        label: { type: 'plain_text', text: 'VM name' },
        element: {
          type: 'plain_text_input',
          action_id: 'val',
          min_length: 3,
          max_length: 20,
          placeholder: { type: 'plain_text', text: 'lowercase letters, digits, hyphens' },
        },
      },
      {
        type: 'input',
        block_id: 'os_type',
        label: { type: 'plain_text', text: 'Operating system' },
        element: {
          type: 'static_select',
          action_id: 'val',
          initial_option: { text: { type: 'plain_text', text: OS_LABELS['amazon-linux'] }, value: 'amazon-linux' },
          options: osOptions,
        },
      },
      {
        type: 'input',
        block_id: 'memory_gb',
        label: { type: 'plain_text', text: 'Memory (GB)' },
        element: {
          type: 'number_input',
          action_id: 'val',
          is_decimal_allowed: false,
          min_value: String(MEM_MIN_GB),
          max_value: String(MEM_MAX_GB),
          initial_value: '2',
        },
      },
      {
        type: 'input',
        block_id: 'disk_gb',
        label: { type: 'plain_text', text: 'Disk size (GB)' },
        element: {
          type: 'number_input',
          action_id: 'val',
          is_decimal_allowed: false,
          min_value: String(DISK_MIN_GB),
          max_value: String(DISK_MAX_GB),
          initial_value: '25',
        },
        hint: { type: 'plain_text', text: 'Minimum 25 GB (template size). Larger grows the disk.' },
      },
    ],
  };
}

// ── Handle a completed modal (view_submission) ───────────────────────────────
async function handleViewSubmission(payload) {
  const v = payload.view.state.values;
  const vmName = (v.vm_name?.val?.value || '').trim().toLowerCase();
  const osType = v.os_type?.val?.selected_option?.value || '';
  const memGb = parseInt(v.memory_gb?.val?.value || '', 10);
  const diskGb = parseInt(v.disk_gb?.val?.value || '', 10);
  const userId = payload.user?.id || '';

  const errors = {};
  if (!VM_NAME_RE.test(vmName)) errors.vm_name = '3–20 chars, lowercase letters/digits/hyphens, no leading/trailing hyphen.';
  if (!VALID_OS.includes(osType)) errors.os_type = 'Pick a valid OS.';
  if (!(memGb >= MEM_MIN_GB && memGb <= MEM_MAX_GB)) errors.memory_gb = `Between ${MEM_MIN_GB} and ${MEM_MAX_GB} GB.`;
  if (!(diskGb >= DISK_MIN_GB && diskGb <= DISK_MAX_GB)) errors.disk_gb = `Between ${DISK_MIN_GB} and ${DISK_MAX_GB} GB.`;
  if (Object.keys(errors).length) return ok({ response_action: 'errors', errors });

  await triggerWorkflow('create-vm.yml', {
    os_type: osType,
    vm_name: vmName,
    slack_user_id: userId,
    memory: String(memGb * 1024), // MB
    disk_gb: String(diskGb),
  });

  // Close the modal, then DM the user an acknowledgement (best effort).
  if (SLACK_BOT_TOKEN) {
    slackApi('chat.postMessage', {
      channel: userId,
      text: `:hourglass_flowing_sand: Creating *${OS_LABELS[osType]}* VM \`${vmName}\` (${memGb} GB RAM, ${diskGb} GB disk)...\nYou'll get a DM when it's ready (2–5 min).`,
    }).catch(() => {});
  }
  return ok(); // empty 200 closes the modal
}

// ── Main handler ─────────────────────────────────────────────────────────────
exports.handler = async (event) => {
  const headers = Object.fromEntries(
    Object.entries(event.headers || {}).map(([k, v]) => [k.toLowerCase(), v])
  );
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body || '', 'base64').toString('utf-8')
    : (event.body || '');

  if (!verifySlackSignature(headers, rawBody)) {
    console.error('Signature verification failed', {
      hasTimestamp: !!headers['x-slack-request-timestamp'],
      hasSignature: !!headers['x-slack-signature'],
      bodyLength: rawBody.length,
      isBase64Encoded: event.isBase64Encoded,
    });
    return ephemeral(':x: Request verification failed. Check SLACK_SIGNING_SECRET.');
  }

  const params = Object.fromEntries(new URLSearchParams(rawBody));

  try {
    // ── Interactivity payloads (modal submit / actions) ──────────────────────
    if (params.payload) {
      const payload = JSON.parse(params.payload);
      if (payload.type === 'view_submission' && payload.view?.callback_id === 'create_vm_modal') {
        return await handleViewSubmission(payload);
      }
      return ok(); // ack anything else
    }

    const command = params.command || '';
    const text = (params.text || '').trim().toLowerCase();
    const userId = params.user_id || '';

    // ── /create-vm → open the modal ──────────────────────────────────────────
    if (command === '/create-vm') {
      if (!SLACK_BOT_TOKEN) {
        return ephemeral(':x: Server not configured for the form (missing SLACK_BOT_TOKEN). Ask an administrator.');
      }
      if (!params.trigger_id) return ephemeral(':x: Could not open the form (no trigger_id).');
      await slackApi('views.open', { trigger_id: params.trigger_id, view: createVmModal() });
      return ok(); // empty 200 acks the slash command; the modal is already open
    }

    // ── /delete-vm <name> ────────────────────────────────────────────────────
    if (command === '/delete-vm') {
      if (!text || !VM_NAME_RE.test(text)) return ephemeral('Usage: `/delete-vm <name>`');
      await triggerWorkflow('delete-vm.yml', { vm_name: text, slack_user_id: userId });
      return ephemeral(`:hourglass_flowing_sand: Deleting VM \`${text}\`... You'll receive a DM when done.`);
    }

    // ── /list-vms ────────────────────────────────────────────────────────────
    if (command === '/list-vms') {
      await triggerWorkflow('list-vms.yml', { slack_user_id: userId });
      return ephemeral(':hourglass_flowing_sand: Fetching your VMs... check your DMs shortly.');
    }

    return ephemeral('Unknown command.');
  } catch (err) {
    console.error('Handler error:', err.message);
    return ephemeral(':x: Something went wrong. Please try again or contact an administrator.');
  }
};
