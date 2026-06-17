require('dotenv').config();
const { App } = require('@slack/bolt');
const { triggerWorkflow } = require('./utils/github');

const app = new App({
  token: process.env.SLACK_BOT_TOKEN,
  appToken: process.env.SLACK_APP_TOKEN,
  socketMode: true,
});

const VALID_OS = ['ubuntu', 'amazon-linux', 'windows-server'];

// VM name: 3-20 chars, lowercase alphanumeric + hyphens, no leading/trailing hyphen
const VM_NAME_RE = /^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$/;

function validateVmName(name) {
  if (!name) return 'VM name is required.';
  if (!VM_NAME_RE.test(name))
    return 'VM name must be 3–20 chars, lowercase alphanumeric and hyphens only (no leading/trailing hyphen).';
  return null;
}

// /create-vm ubuntu my-server
app.command('/create-vm', async ({ command, ack, respond }) => {
  await ack();

  const [osType, vmName] = command.text.trim().toLowerCase().split(/\s+/);

  if (!osType || !VALID_OS.includes(osType)) {
    await respond({
      response_type: 'ephemeral',
      text:
        `Invalid OS. Usage: \`/create-vm <os> <name>\`\n` +
        `Valid options: \`${VALID_OS.join('`, `')}\``,
    });
    return;
  }

  const nameErr = validateVmName(vmName);
  if (nameErr) {
    await respond({ response_type: 'ephemeral', text: nameErr });
    return;
  }

  try {
    await triggerWorkflow('create-vm.yml', {
      os_type: osType,
      vm_name: vmName,
      slack_user_id: command.user_id,
    });

    await respond({
      response_type: 'ephemeral',
      text: `:hourglass_flowing_sand: Creating *${osType}* VM \`${vmName}\`...\nYou'll receive a DM when it's ready (usually 2–5 min).`,
    });
  } catch (err) {
    console.error('Failed to trigger create-vm workflow:', err.response?.data ?? err.message);
    await respond({
      response_type: 'ephemeral',
      text: ':x: Could not start VM creation. Please contact an administrator.',
    });
  }
});

// /delete-vm my-server
app.command('/delete-vm', async ({ command, ack, respond }) => {
  await ack();

  const vmName = command.text.trim().toLowerCase();
  const nameErr = validateVmName(vmName);
  if (nameErr) {
    await respond({ response_type: 'ephemeral', text: `Usage: \`/delete-vm <name>\`\n${nameErr}` });
    return;
  }

  try {
    await triggerWorkflow('delete-vm.yml', {
      vm_name: vmName,
      slack_user_id: command.user_id,
    });

    await respond({
      response_type: 'ephemeral',
      text: `:hourglass_flowing_sand: Deleting VM \`${vmName}\`... You'll receive a DM when done.`,
    });
  } catch (err) {
    console.error('Failed to trigger delete-vm workflow:', err.response?.data ?? err.message);
    await respond({
      response_type: 'ephemeral',
      text: ':x: Could not start VM deletion. Please contact an administrator.',
    });
  }
});

// /list-vms
app.command('/list-vms', async ({ command, ack, respond }) => {
  await ack();

  try {
    await triggerWorkflow('list-vms.yml', {
      slack_user_id: command.user_id,
    });

    await respond({
      response_type: 'ephemeral',
      text: ':hourglass_flowing_sand: Fetching your VMs... check your DMs shortly.',
    });
  } catch (err) {
    console.error('Failed to trigger list-vms workflow:', err.response?.data ?? err.message);
    await respond({
      response_type: 'ephemeral',
      text: ':x: Could not fetch VM list. Please contact an administrator.',
    });
  }
});

(async () => {
  await app.start();
  console.log('Proxmox Cloud bot is running (Socket Mode)');
})();
