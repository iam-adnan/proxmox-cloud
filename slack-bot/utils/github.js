const axios = require('axios');

const { GITHUB_TOKEN, GITHUB_OWNER, GITHUB_REPO } = process.env;

async function triggerWorkflow(workflowFile, inputs) {
  const url = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/workflows/${workflowFile}/dispatches`;

  await axios.post(
    url,
    { ref: 'master', inputs },
    {
      headers: {
        Authorization: `Bearer ${GITHUB_TOKEN}`,
        Accept: 'application/vnd.github.v3+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    }
  );
}

module.exports = { triggerWorkflow };
