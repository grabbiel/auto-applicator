#!/bin/bash
# Sets up (or updates) the optional cloud browser in your AWS account, writes the app's connection file, and manages
# who may sign in. Nobody can sign up: people are invited, and Google or Apple only work for an invited address.
#
#   bash scripts/deploy_cloud.sh                      deploy or update (writes Resources/CloudConfig.json)
#   bash scripts/deploy_cloud.sh --invite a@b.com     invite someone: Cognito emails them a temporary password
#   bash scripts/deploy_cloud.sh --invites            list invitations and how each person signs in
#   bash scripts/deploy_cloud.sh --revoke a@b.com     stop someone signing in and end their sign-ins
#   bash scripts/deploy_cloud.sh --sign-in-setup      what to enter at Google and Apple to offer them
#   bash scripts/deploy_cloud.sh --google CLIENT_ID   offer "Continue with Google" (asks for the client secret)
#   bash scripts/deploy_cloud.sh --apple SERVICES_ID --apple-team TEAM_ID --apple-key KEY_ID --apple-key-file AuthKey.p8
#                                                     offer "Continue with Apple"
#   bash scripts/deploy_cloud.sh --google off         (or --apple off) stop offering it
# Inviting, listing and revoking don't redeploy an existing stack. Rebuild the app after a deploy.
# Environment: AWS_PROFILE (default "admin"), AWS_REGION (default us-east-1), AA_STACK (default auto-applicator-cloud),
# AA_GOOGLE_CLIENT_SECRET (instead of typing it). Tear everything down with:
#   aws cloudformation delete-stack --stack-name auto-applicator-cloud
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-admin}" AWS_REGION="${AWS_REGION:-us-east-1}" AWS_PAGER=""
STACK="${AA_STACK:-auto-applicator-cloud}"
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
INVITE="" REVOKE="" LIST=0 SETUP=0 GOOGLE="" APPLE="" APPLE_TEAM="" APPLE_KEY="" APPLE_KEY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --invite) INVITE="$(lower "${2:?an email address}")"; shift 2 ;;
    --revoke) REVOKE="$(lower "${2:?an email address}")"; shift 2 ;;
    --invites) LIST=1; shift ;;
    --sign-in-setup) SETUP=1; shift ;;
    --google) GOOGLE="${2:?a client ID, or off}"; shift 2 ;;
    --apple) APPLE="${2:?a Services ID, or off}"; shift 2 ;;
    --apple-team) APPLE_TEAM="${2:?a team ID}"; shift 2 ;;
    --apple-key) APPLE_KEY="${2:?a key ID}"; shift 2 ;;
    --apple-key-file) APPLE_KEY_FILE="${2:?a .p8 file}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
done
ID='^[A-Za-z0-9._-]+$'
[ -z "$GOOGLE" ] || [ "$GOOGLE" = off ] || [[ "$GOOGLE" =~ $ID ]] || { echo "That doesn't look like a Google client ID." >&2; exit 64; }
if [ -n "$APPLE" ] && [ "$APPLE" != off ]; then
  [ -n "$APPLE_TEAM" ] && [ -n "$APPLE_KEY" ] && [ -n "$APPLE_KEY_FILE" ] \
    || { echo "--apple also needs --apple-team, --apple-key and --apple-key-file." >&2; exit 64; }
  for v in "$APPLE" "$APPLE_TEAM" "$APPLE_KEY"; do [[ "$v" =~ $ID ]] || { echo "Not an Apple ID: $v" >&2; exit 64; }; done
  head -1 "$APPLE_KEY_FILE" 2>/dev/null | grep -q -- "-----BEGIN PRIVATE KEY-----" \
    || { echo "$APPLE_KEY_FILE isn't the AuthKey_….p8 file Apple gave you." >&2; exit 64; }
fi

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
PREFIX="auto-applicator-$ACCOUNT"
HOST="$PREFIX.auth.$AWS_REGION.amazoncognito.com"

if [ "$SETUP" = 1 ]; then
  cat <<TXT
Google: at console.cloud.google.com/auth/clients (the first time, it asks for the app's name and audience: choose
External, and add your Google address as a test user) → Create client → Web application:
  Authorized JavaScript origins:  https://$HOST
  Authorized redirect URIs:       https://$HOST/oauth2/idpresponse
Then:  bash scripts/deploy_cloud.sh --google <client ID>     (it asks for the client secret)

Apple (needs the Apple Developer Program): at developer.apple.com/account/resources
  1. Identifiers → App IDs: one with "Sign in with Apple" turned on (an existing one is fine).
  2. Identifiers → Services IDs: a new one (its identifier is the Services ID). Turn on Sign in with Apple →
     Configure, pick that App ID, and enter
       Domains and Subdomains:  $HOST
       Return URLs:             https://$HOST/oauth2/idpresponse
  3. Keys: a new key with Sign in with Apple. Download AuthKey_<key ID>.p8 (Apple offers it only once).
  Your team ID is at the top right of the developer site.
Then:  bash scripts/deploy_cloud.sh --apple <Services ID> --apple-team <team ID> --apple-key <key ID> --apple-key-file AuthKey_<key ID>.p8
TXT
  exit 0
fi

exists() { aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; }
out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
param() {
  local v; v="$(aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue" --output text)"
  [ "$v" = true ] && echo true || echo false
}
DEPLOYED=0
deploy() {
  echo "Deploying $STACK to account $ACCOUNT ($AWS_REGION)…"
  aws cloudformation deploy \
    --stack-name "$STACK" \
    --template-file "$ROOT/infra/cloud-browser.yaml" \
    --parameter-overrides "DomainPrefix=$PREFIX" "GoogleSignIn=$G" "AppleSignIn=$A" \
    --capabilities CAPABILITY_IAM \
    --tags App=auto-applicator \
    --no-fail-on-empty-changeset
  DEPLOYED=1
}

G=false A=false EXISTS=0
if exists; then EXISTS=1 G="$(param GoogleSignIn)" A="$(param AppleSignIn)"; fi
WAS="$G$A"
# Inviting, listing and revoking leave an existing stack as it is.
MANAGE_ONLY=0
if [ -z "$GOOGLE$APPLE" ] && { [ -n "$INVITE$REVOKE" ] || [ "$LIST" = 1 ]; }; then MANAGE_ONLY=1; fi
if [ "$EXISTS" = 0 ] || [ "$MANAGE_ONLY" = 0 ]; then deploy; fi
POOL="$(out UserPoolId)"

# Google and Apple: their secrets go to Cognito in a file only this script can read, never on a command line.
umask 077
DETAILS="$(mktemp)"
trap 'rm -f "$DETAILS"' EXIT
provider() {  # name, type
  local mapping="email=email,email_verified=email_verified"
  if aws cognito-idp describe-identity-provider --user-pool-id "$POOL" --provider-name "$1" >/dev/null 2>&1; then
    aws cognito-idp update-identity-provider --user-pool-id "$POOL" --provider-name "$1" \
      --provider-details "file://$DETAILS" --attribute-mapping "$mapping" >/dev/null
  else
    aws cognito-idp create-identity-provider --user-pool-id "$POOL" --provider-name "$1" --provider-type "$2" \
      --provider-details "file://$DETAILS" --attribute-mapping "$mapping" >/dev/null
  fi
  : >"$DETAILS"
}
if [ -n "$GOOGLE" ] && [ "$GOOGLE" != off ]; then
  SECRET="${AA_GOOGLE_CLIENT_SECRET:-}"
  if [ -z "$SECRET" ]; then
    [ -t 0 ] || { echo "Set AA_GOOGLE_CLIENT_SECRET, or run this in a terminal to type it." >&2; exit 64; }
    read -rsp "Google client secret (not shown): " SECRET; echo
  fi
  [[ "$SECRET" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "That doesn't look like a Google client secret." >&2; exit 64; }
  printf '{"client_id":"%s","client_secret":"%s","authorize_scopes":"openid email"}' "$GOOGLE" "$SECRET" >"$DETAILS"
  unset SECRET
  provider Google Google
  G=true
fi
if [ -n "$APPLE" ] && [ "$APPLE" != off ]; then
  # A .p8 key is base64 between two marker lines, so its line breaks are all JSON needs escaped.
  printf '{"client_id":"%s","team_id":"%s","key_id":"%s","private_key":"%s","authorize_scopes":"email"}' \
    "$APPLE" "$APPLE_TEAM" "$APPLE_KEY" "$(awk '{printf "%s\\n", $0}' "$APPLE_KEY_FILE")" >"$DETAILS"
  provider SignInWithApple SignInWithApple
  A=true
fi
[ "$GOOGLE" = off ] && G=false
[ "$APPLE" = off ] && A=false
if [ "$G$A" != "$WAS" ]; then deploy; fi   # offers (or stops offering) them on the sign-in page
# A provider leaves the pool only after the sign-in page stopped offering it.
[ "$GOOGLE" = off ] && aws cognito-idp delete-identity-provider --user-pool-id "$POOL" --provider-name Google 2>/dev/null || true
[ "$APPLE" = off ] && aws cognito-idp delete-identity-provider --user-pool-id "$POOL" --provider-name SignInWithApple 2>/dev/null || true

if [ "$DEPLOYED" = 1 ]; then
  PROVIDERS="$(aws cognito-idp describe-user-pool-client --user-pool-id "$POOL" --client-id "$(out ClientId)" \
    --query 'UserPoolClient.SupportedIdentityProviders' --output text | tr '\t' '\n' | grep -vx COGNITO | sed 's/.*/"&"/' | paste -sd, - || true)"
  mkdir -p "$ROOT/Resources"
  cat >"$ROOT/Resources/CloudConfig.json" <<JSON
{
  "region": "$(out Region)",
  "userPoolId": "$POOL",
  "clientId": "$(out ClientId)",
  "signInHost": "$(out SignInHost)",
  "identityPoolId": "$(out IdentityPoolId)",
  "browserId": "$(out BrowserId)",
  "browserProfileId": "$(out BrowserProfileId)",
  "signInProviders": [$PROVIDERS]
}
JSON
  echo "Wrote Resources/CloudConfig.json (rebuild the app to include it)."
fi

OFFERS=""
[ "$G" = true ] && OFFERS="Google"
[ "$A" = true ] && OFFERS="${OFFERS:+$OFFERS or }Apple"
if [ -n "$INVITE" ]; then
  STATUS="$(aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$INVITE" --query '[UserStatus, Enabled]' --output text 2>/dev/null || true)"
  case "$STATUS" in
    "")
      aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$INVITE" \
        --user-attributes Name=email,Value="$INVITE" Name=email_verified,Value=true \
        --desired-delivery-mediums EMAIL >/dev/null
      echo "Invited $INVITE: Cognito emailed a temporary password (valid 7 days)${OFFERS:+; Continue with $OFFERS works for this address too}." ;;
    *False) aws cognito-idp admin-enable-user --user-pool-id "$POOL" --username "$INVITE"
      echo "$INVITE can sign in again." ;;
    FORCE_CHANGE_PASSWORD*)
      aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$INVITE" --message-action RESEND \
        --desired-delivery-mediums EMAIL >/dev/null
      echo "Sent $INVITE's invitation again, with a new temporary password." ;;
    *) echo "$INVITE already has an account." ;;
  esac
fi
if [ -n "$REVOKE" ]; then
  aws cognito-idp admin-disable-user --user-pool-id "$POOL" --username "$REVOKE"
  aws cognito-idp admin-user-global-sign-out --user-pool-id "$POOL" --username "$REVOKE"
  echo "Revoked $REVOKE: they can't sign in, and their app loses the cloud browser within the hour."
  echo "(--invite lets them back in. To delete the account: aws cognito-idp admin-delete-user --user-pool-id $POOL --username $REVOKE)"
fi
if [ "$LIST" = 1 ]; then
  USERS="$(aws cognito-idp list-users --user-pool-id "$POOL" --output text \
    --query 'Users[].[Attributes[?Name==`email`]|[0].Value, UserStatus, Enabled, Attributes[?Name==`identities`]|[0].Value]')"
  [ -n "$USERS" ] || echo "No invitations yet: bash scripts/deploy_cloud.sh --invite <email>"
  [ -z "$USERS" ] || while IFS=$'\t' read -r email status enabled identities; do
    linked=""
    case "$identities" in *'"Google"'*) linked="Google" ;; esac
    case "$identities" in *'"SignInWithApple"'*) linked="${linked:+$linked, }Apple" ;; esac
    case "$enabled/$status/$linked" in
      False/*) state="revoked" ;;
      */FORCE_CHANGE_PASSWORD/) state="invited, not signed in yet" ;;
      */FORCE_CHANGE_PASSWORD/*) state="signs in with $linked (no password yet)" ;;
      *) state="signs in with password or passkey${linked:+, $linked}" ;;
    esac
    printf '%-36s %s\n' "$email" "$state"
  done <<<"$USERS"
fi
[ -n "$OFFERS" ] || [ "$DEPLOYED" = 0 ] || echo "To offer Google or Apple sign-in: bash scripts/deploy_cloud.sh --sign-in-setup"
[ "$DEPLOYED" = 0 ] || echo "Resources: https://$AWS_REGION.console.aws.amazon.com/resource-groups/group/auto-applicator"
