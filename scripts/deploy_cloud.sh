#!/bin/bash
# Sets up (or updates) the optional cloud browser in your AWS account and writes the app's connection file.
#   Usage:  bash scripts/deploy_cloud.sh [--invite you@example.com]
#     --invite   creates the one sign-in account; Cognito emails that address a temporary password.
# Environment: AWS_PROFILE (default "admin"), AWS_REGION (default us-east-1), AA_STACK (default auto-applicator-cloud).
# Writes Resources/CloudConfig.json, which scripts/build_app.sh copies into the app. Tear everything down with:
#   aws cloudformation delete-stack --stack-name auto-applicator-cloud
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-admin}" AWS_REGION="${AWS_REGION:-us-east-1}" AWS_PAGER=""
STACK="${AA_STACK:-auto-applicator-cloud}"
INVITE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --invite) INVITE="${2:?an email address}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
PREFIX="auto-applicator-$ACCOUNT"
echo "Deploying $STACK to account $ACCOUNT ($AWS_REGION)…"
aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file "$ROOT/infra/cloud-browser.yaml" \
  --parameter-overrides "DomainPrefix=$PREFIX" \
  --capabilities CAPABILITY_IAM \
  --tags App=auto-applicator \
  --no-fail-on-empty-changeset

out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
mkdir -p "$ROOT/Resources"
cat > "$ROOT/Resources/CloudConfig.json" <<JSON
{
  "region": "$(out Region)",
  "userPoolId": "$(out UserPoolId)",
  "clientId": "$(out ClientId)",
  "signInHost": "$(out SignInHost)",
  "identityPoolId": "$(out IdentityPoolId)",
  "browserId": "$(out BrowserId)",
  "browserProfileId": "$(out BrowserProfileId)"
}
JSON
echo "Wrote Resources/CloudConfig.json (rebuild the app to include it)."

if [ -n "$INVITE" ]; then
  POOL="$(out UserPoolId)"
  if aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$INVITE" >/dev/null 2>&1; then
    echo "$INVITE already has an account."
  else
    aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$INVITE" \
      --user-attributes Name=email,Value="$INVITE" Name=email_verified,Value=true \
      --desired-delivery-mediums EMAIL >/dev/null
    echo "Invited $INVITE: Cognito emailed a temporary password (valid 7 days)."
  fi
fi
echo "Resources: https://$AWS_REGION.console.aws.amazon.com/resource-groups/group/auto-applicator"
