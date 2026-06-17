#!/bin/bash
# Deploy or update the Lambda function.
# Prerequisites: AWS CLI configured, LAMBDA_ROLE_ARN set on first deploy.
#
# Usage:
#   First deploy:  LAMBDA_ROLE_ARN=arn:aws:iam::123456789:role/my-role bash deploy.sh
#   Update code:   bash deploy.sh
set -euo pipefail

FUNCTION_NAME="proxmox-cloud-bot"
REGION="${AWS_REGION:-us-east-1}"
RUNTIME="nodejs20.x"
TIMEOUT=10

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ">> Packaging Lambda..."
cd "$SCRIPT_DIR"
zip -q function.zip index.js

# ── Create or update ─────────────────────────────────────────────────────────
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" &>/dev/null; then
  echo ">> Updating function code..."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://function.zip \
    --region "$REGION" \
    --output text --query 'FunctionArn' | xargs -I{} echo "   ARN: {}"
else
  ROLE_ARN="${LAMBDA_ROLE_ARN:?First deploy requires LAMBDA_ROLE_ARN env var (IAM role ARN)}"

  echo ">> Creating Lambda function..."
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime "$RUNTIME" \
    --handler index.handler \
    --role "$ROLE_ARN" \
    --zip-file fileb://function.zip \
    --timeout "$TIMEOUT" \
    --region "$REGION" \
    --output text --query 'FunctionArn' | xargs -I{} echo "   ARN: {}"

  echo ">> Creating Function URL (public HTTPS endpoint for Slack)..."
  aws lambda create-function-url-config \
    --function-name "$FUNCTION_NAME" \
    --auth-type NONE \
    --cors "{
      \"AllowOrigins\": [\"https://slack.com\"],
      \"AllowMethods\": [\"POST\"],
      \"AllowHeaders\": [\"content-type\",\"x-slack-signature\",\"x-slack-request-timestamp\"]
    }" \
    --region "$REGION" \
    --output text --query 'FunctionUrl' | xargs -I{} echo "   URL: {}"

  echo ">> Granting public invoke permission..."
  aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --action lambda:InvokeFunctionUrl \
    --principal "*" \
    --function-url-auth-type NONE \
    --statement-id allow-slack-invoke \
    --region "$REGION" \
    --output text --query 'Statement' > /dev/null
fi

rm -f function.zip

# ── Print Function URL ────────────────────────────────────────────────────────
FUNCTION_URL="$(aws lambda get-function-url-config \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION" \
  --query FunctionUrl \
  --output text)"

echo ""
echo "Done!"
echo ""
echo "Function URL: $FUNCTION_URL"
echo ""
echo "Set this as the Request URL for each Slack slash command:"
echo "  /create-vm  →  $FUNCTION_URL"
echo "  /delete-vm  →  $FUNCTION_URL"
echo "  /list-vms   →  $FUNCTION_URL"
echo ""
echo "Set these environment variables in the Lambda console (Configuration → Environment variables):"
echo "  SLACK_SIGNING_SECRET"
echo "  GITHUB_TOKEN"
echo "  GITHUB_OWNER=iam-adnan"
echo "  GITHUB_REPO=proxmox-cloud"
