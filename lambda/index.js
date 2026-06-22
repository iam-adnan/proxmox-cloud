/**
 * AWS Lambda handler — Slack entrypoint (behind an API Gateway HTTP API).
 *
 * /create-vm  -> opens a modal with ONE grouped "What to create" dropdown
 *                (VMs + containers), plus name, cores, memory, disk, unprivileged
 *                (containers only), start-on-boot, and a description note.
 * modal submit (view_submission) -> validates and triggers create-vm.yml (a "vm:"
 *                choice) or create-container.yml (a "ct:" choice).
 * /delete-vm <name>, /list-vms -> text slash commands (cover VMs and containers).
 *
 * The resource dropdown value encodes BOTH kind and OS as `vm:<os>` / `ct:<tmpl>`
 * so the modal is fully static — no dynamic re-render. (An earlier version used a
 * type toggle with dispatch_action + views.update, but Slack does not reliably
 * re-render an input block's options that way, so the OS list went stale.)
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

// ── VM operating systems (qm) ────────────────────────────────────────────────
const VALID_VM_OS = ['ubuntu', 'amazon-linux', 'windows-server'];
const VM_OS_LABELS = {
  ubuntu: 'Ubuntu Server',
  'amazon-linux': 'Amazon Linux 2023',
  'windows-server': 'Windows Server',
};

// ── Container templates (pct / pveam) ────────────────────────────────────────
const VALID_CT_TEMPLATES = ['ubuntu-22.04'];
const CT_TEMPLATE_LABELS = {
  'ubuntu-22.04': 'Ubuntu 22.04',
};

// Combined dropdown values: `vm:<os>` and `ct:<template>`.
const RESOURCE_VALUES = [
  ...VALID_VM_OS.map((o) => `vm:${o}`),
  ...VALID_CT_TEMPLATES.map((t) => `ct:${t}`),
];

const VM_NAME_RE = /^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$/;
const NOTE_MAX = 100;
const CORES_MIN = 1, CORES_MAX = 16;
const MEM_MIN_GB = 1, MEM_MAX_GB = 64;
const DISK_MAX_GB = 500;
const VM_DISK_MIN_GB = 25;  // template disk size; can only grow
const CT_DISK_MIN_GB = 4;   // LXC rootfs is created fresh at the requested size

// Strip anything that could break shell interpolation in the workflow; the note
// is interpolated into bash via `${{ inputs.note }}`, so keep it to a safe set.
function sanitizeNote(s) {
  return (s || '').replace(/[^A-Za-z0-9 _.,:/()-]/g, '').slice(0, NOTE_MAX).trim();
}

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

// ── Modal (fully static — one grouped resource dropdown) ─────────────────────
function createModal() {
  const resourceElement = {
    type: 'static_select',
    action_id: 'val',
    placeholder: { type: 'plain_text', text: 'Select what to create' },
    option_groups: [
      {
        label: { type: 'plain_text', text: 'Virtual machines' },
        options: VALID_VM_OS.map((o) => ({
          text: { type: 'plain_text', text: VM_OS_LABELS[o] },
          value: `vm:${o}`,
        })),
      },
      {
        label: { type: 'plain_text', text: 'Containers (LXC)' },
        options: VALID_CT_TEMPLATES.map((t) => ({
          text: { type: 'plain_text', text: CT_TEMPLATE_LABELS[t] },
          value: `ct:${t}`,
        })),
      },
    ],
  };

  return {
    type: 'modal',
    callback_id: 'create_vm_modal',
    title: { type: 'plain_text', text: 'Create a resource' },
    submit: { type: 'plain_text', text: 'Create' },
    close: { type: 'plain_text', text: 'Cancel' },
    blocks: [
      {
        type: 'input',
        block_id: 'resource',
        label: { type: 'plain_text', text: 'What to create' },
        element: resourceElement,
      },
      {
        type: 'input',
        block_id: 'vm_name',
        label: { type: 'plain_text', text: 'Name' },
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
        block_id: 'cores',
        label: { type: 'plain_text', text: 'CPU cores' },
        element: {
          type: 'number_input', action_id: 'val', is_decimal_allowed: false,
          min_value: String(CORES_MIN), max_value: String(CORES_MAX), initial_value: '2',
        },
      },
      {
        type: 'input',
        block_id: 'memory_gb',
        label: { type: 'plain_text', text: 'Memory (GB)' },
        element: {
          type: 'number_input', action_id: 'val', is_decimal_allowed: false,
          min_value: String(MEM_MIN_GB), max_value: String(MEM_MAX_GB), initial_value: '2',
        },
      },
      {
        type: 'input',
        block_id: 'disk_gb',
        label: { type: 'plain_text', text: 'Disk size (GB)' },
        element: {
          type: 'number_input', action_id: 'val', is_decimal_allowed: false,
          min_value: String(CT_DISK_MIN_GB), max_value: String(DISK_MAX_GB), initial_value: '25',
        },
        hint: { type: 'plain_text', text: `VMs: min ${VM_DISK_MIN_GB} GB (template size). Containers: min ${CT_DISK_MIN_GB} GB.` },
      },
      {
        type: 'input',
        block_id: 'unprivileged',
        optional: true,
        label: { type: 'plain_text', text: 'Container security' },
        element: {
          type: 'checkboxes', action_id: 'val',
          initial_options: [
            { text: { type: 'plain_text', text: 'Unprivileged container (recommended; ignored for VMs)' }, value: 'unprivileged' },
          ],
          options: [
            { text: { type: 'plain_text', text: 'Unprivileged container (recommended; ignored for VMs)' }, value: 'unprivileged' },
          ],
        },
      },
      {
        type: 'input',
        block_id: 'onboot',
        optional: true,
        label: { type: 'plain_text', text: 'Startup' },
        element: {
          type: 'checkboxes', action_id: 'val',
          options: [
            { text: { type: 'plain_text', text: 'Start automatically when the host boots' }, value: 'onboot' },
          ],
        },
      },
      {
        type: 'input',
        block_id: 'note',
        optional: true,
        label: { type: 'plain_text', text: 'Description / purpose' },
        element: {
          type: 'plain_text_input', action_id: 'val', max_length: NOTE_MAX,
          placeholder: { type: 'plain_text', text: 'optional note (e.g. "demo box for project X")' },
        },
      },
    ],
  };
}

// ── Handle a completed modal (view_submission) ───────────────────────────────
async function handleViewSubmission(payload) {
  const v = payload.view.state.values;
  const resourceVal = v.resource?.val?.selected_option?.value || '';
  const [resourceType, osType] = resourceVal.split(':');
  const isCt = resourceType === 'ct';

  const name = (v.vm_name?.val?.value || '').trim().toLowerCase();
  const cores = parseInt(v.cores?.val?.value || '', 10);
  const memGb = parseInt(v.memory_gb?.val?.value || '', 10);
  const diskGb = parseInt(v.disk_gb?.val?.value || '', 10);
  const note = sanitizeNote(v.note?.val?.value || '');
  const onboot = (v.onboot?.val?.selected_options || []).length > 0;
  const unprivileged = (v.unprivileged?.val?.selected_options || []).length > 0;
  const userId = payload.user?.id || '';

  const diskMin = isCt ? CT_DISK_MIN_GB : VM_DISK_MIN_GB;

  const errors = {};
  if (!RESOURCE_VALUES.includes(resourceVal)) errors.resource = 'Pick what to create.';
  if (!VM_NAME_RE.test(name)) errors.vm_name = '3–20 chars, lowercase letters/digits/hyphens, no leading/trailing hyphen.';
  if (!(cores >= CORES_MIN && cores <= CORES_MAX)) errors.cores = `Between ${CORES_MIN} and ${CORES_MAX}.`;
  if (!(memGb >= MEM_MIN_GB && memGb <= MEM_MAX_GB)) errors.memory_gb = `Between ${MEM_MIN_GB} and ${MEM_MAX_GB} GB.`;
  if (!(diskGb >= diskMin && diskGb <= DISK_MAX_GB)) {
    errors.disk_gb = isCt
      ? `Containers: ${CT_DISK_MIN_GB}–${DISK_MAX_GB} GB.`
      : `VMs need at least ${VM_DISK_MIN_GB} GB (template size); max ${DISK_MAX_GB}.`;
  }
  if (Object.keys(errors).length) return ok({ response_action: 'errors', errors });

  if (isCt) {
    await triggerWorkflow('create-container.yml', {
      template: osType,
      vm_name: name,
      slack_user_id: userId,
      cores: String(cores),
      memory: String(memGb * 1024), // MB
      disk_gb: String(diskGb),
      unprivileged: unprivileged ? '1' : '0',
      onboot: onboot ? '1' : '0',
      note,
    });
  } else {
    await triggerWorkflow('create-vm.yml', {
      os_type: osType,
      vm_name: name,
      slack_user_id: userId,
      cores: String(cores),
      memory: String(memGb * 1024), // MB
      disk_gb: String(diskGb),
      onboot: onboot ? '1' : '0',
      note,
    });
  }

  // Close the modal, then DM the user an acknowledgement (best effort).
  if (SLACK_BOT_TOKEN) {
    const label = isCt ? `${CT_TEMPLATE_LABELS[osType]} container` : `${VM_OS_LABELS[osType]} VM`;
    slackApi('chat.postMessage', {
      channel: userId,
      text: `:hourglass_flowing_sand: Creating *${label}* \`${name}\` (${cores} cores, ${memGb} GB RAM, ${diskGb} GB disk)...\nYou'll get a DM when it's ready (containers ~1–2 min, VMs 2–5 min).`,
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
    // ── Interactivity payloads (modal submit) ────────────────────────────────
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
      await slackApi('views.open', { trigger_id: params.trigger_id, view: createModal() });
      return ok(); // empty 200 acks the slash command; the modal is already open
    }

    // ── /delete-vm <name> ────────────────────────────────────────────────────
    if (command === '/delete-vm') {
      if (!text || !VM_NAME_RE.test(text)) return ephemeral('Usage: `/delete-vm <name>`');
      await triggerWorkflow('delete-vm.yml', { vm_name: text, slack_user_id: userId });
      return ephemeral(`:hourglass_flowing_sand: Deleting \`${text}\`... You'll receive a DM when done.`);
    }

    // ── /list-vms ────────────────────────────────────────────────────────────
    if (command === '/list-vms') {
      await triggerWorkflow('list-vms.yml', { slack_user_id: userId });
      return ephemeral(':hourglass_flowing_sand: Fetching your VMs and containers... check your DMs shortly.');
    }

    return ephemeral('Unknown command.');
  } catch (err) {
    console.error('Handler error:', err.message);
    return ephemeral(':x: Something went wrong. Please try again or contact an administrator.');
  }
};
