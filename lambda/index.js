/**
 * AWS Lambda handler — receives Slack slash commands and triggers
 * the appropriate GitHub Actions workflow via workflow_dispatch.
 *
 * Uses only Node.js built-ins (crypto, https) — no npm install needed.
 */

const crypto = require('crypto');
const https = require('https');

const {
  SLACK_SIGNING_SECRET,
  GITHUB_TOKEN,
  GITHUB_OWNER,
  GITHUB_REPO,
} = process.env;

const VALID_OS = ['ubuntu', 'amazon-linux', 'windows-server'];
const VM_NAME_RE = /^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$/;

// ── Slack signature verification ─────────────────────────────────────────────
function verifySlackSignature(headers, rawBody) {
  const timestamp = headers['x-slack-request-timestamp'];
  const slackSig = headers['x-slack-signature'];

  if (!timestamp || !slackSig) return false;

  // Reject requests older than 5 minutes (replay attack prevention)
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
        // 204 No Content = success
        if (res.statusCode === 204) return resolve();
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () =>
          reject(new Error(`GitHub API ${res.statusCode}: ${body}`))
        );
      }
    );

    req.on('error', reject);
    req.write(payload);
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

// ── Main handler ─────────────────────────────────────────────────────────────
exports.handler = async (event) => {
  // Normalise headers to lowercase (Lambda Function URL preserves casing)
  const headers = Object.fromEntries(
    Object.entries(event.headers || {}).map(([k, v]) => [k.toLowerCase(), v])
  );

  // Lambda Function URL may base64-encode the body — decode it first so the
  // HMAC is computed on the original raw bytes that Slack signed.
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
    // Return 200 with error text — Slack treats non-200 as "app did not respond"
    return ephemeral(':x: Request verification failed. Check SLACK_SIGNING_SECRET.');
  }

  const params = Object.fromEntries(new URLSearchParams(rawBody));
  const command = params.command || '';
  const text = (params.text || '').trim().toLowerCase();
  const userId = params.user_id || '';

  try {
    // ── /create-vm <os> <name> ───────────────────────────────────────────────
    if (command === '/create-vm') {
      const [osType, vmName] = text.split(/\s+/);

      if (!osType || !VALID_OS.includes(osType)) {
        return ephemeral(
          `Invalid OS. Usage: \`/create-vm <os> <name>\`\nValid options: \`${VALID_OS.join('`, `')}\``
        );
      }

      if (!vmName || !VM_NAME_RE.test(vmName)) {
        return ephemeral(
          'Invalid VM name. Must be 3–20 chars, lowercase alphanumeric and hyphens only (no leading/trailing hyphen).'
        );
      }

      await triggerWorkflow('create-vm.yml', {
        os_type: osType,
        vm_name: vmName,
        slack_user_id: userId,
      });

      return ephemeral(
        `:hourglass_flowing_sand: Creating *${osType}* VM \`${vmName}\`...\nYou'll receive a DM when it's ready (2–5 min).`
      );
    }

    // ── /delete-vm <name> ────────────────────────────────────────────────────
    if (command === '/delete-vm') {
      if (!text || !VM_NAME_RE.test(text)) {
        return ephemeral('Usage: `/delete-vm <name>`');
      }

      await triggerWorkflow('delete-vm.yml', {
        vm_name: text,
        slack_user_id: userId,
      });

      return ephemeral(
        `:hourglass_flowing_sand: Deleting VM \`${text}\`... You'll receive a DM when done.`
      );
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
