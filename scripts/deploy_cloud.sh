#!/bin/bash
# Sets up (or updates) the optional cloud browser in your AWS account, writes the app's connection file, and manages
# who may sign in. Nobody can sign up: people are invited, and Google or Apple only work for an invited address.
# Each invited person gets a browser and a cookie profile of their own; their sign-in can use nothing else in your
# account (not anyone else's browser, and the cloud AI only if you turn it on for them).
#
#   bash scripts/deploy_cloud.sh                      deploy or update (writes Resources/CloudConfig.json)
#   bash scripts/deploy_cloud.sh --invite a@b.com     invite someone: Cognito emails them a temporary password
#   bash scripts/deploy_cloud.sh --invites            list invitations and how each person signs in
#   bash scripts/deploy_cloud.sh --cloud-ai a@b.com on   let someone ask the cloud AI too (off takes it back)
#   bash scripts/deploy_cloud.sh --stop a@b.com       end the browser sessions someone has running
#   bash scripts/deploy_cloud.sh --revoke a@b.com     lock someone out now (--invite lets them back in)
#   bash scripts/deploy_cloud.sh --remove a@b.com     delete someone's account, browser and saved cookies
#   bash scripts/deploy_cloud.sh --tidy               delete browsers and cookies no account uses any more
#   bash scripts/deploy_cloud.sh --test-browser       a browser for the cloud tests (writes Resources/CloudTest.json)
#   bash scripts/deploy_cloud.sh --sign-in-setup      what to enter at Google and Apple to offer them
#   bash scripts/deploy_cloud.sh --google CLIENT_ID   offer "Continue with Google" (asks for the client secret)
#   bash scripts/deploy_cloud.sh --apple SERVICES_ID --apple-team TEAM_ID --apple-key KEY_ID --apple-key-file AuthKey.p8
#                                                     offer "Continue with Apple"
#   bash scripts/deploy_cloud.sh --google off         (or --apple off) stop offering it
# Managing people doesn't redeploy an existing stack. Rebuild the app after a deploy.
# Environment: AWS_PROFILE (default "admin"), AWS_REGION (default us-east-1), AA_STACK (default auto-applicator-cloud),
# AA_GOOGLE_CLIENT_SECRET (instead of typing it), AA_HELPER_MODEL (the cloud AI: a us.… inference profile, default
# us.amazon.nova-2-lite-v1:0, then whatever the last deploy used; us.anthropic.claude-sonnet-4-6 once Anthropic's
# use-case form is submitted in the Bedrock console). To tear everything down, --remove each person, then:
#   aws cloudformation delete-stack --stack-name auto-applicator-cloud
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-admin}" AWS_REGION="${AWS_REGION:-us-east-1}" AWS_PAGER=""
STACK="${AA_STACK:-auto-applicator-cloud}"
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
INVITE="" REVOKE="" REMOVE="" STOP="" AI="" AI_ON="" LIST=0 TIDY=0 TESTS=0 SETUP=0
GOOGLE="" APPLE="" APPLE_TEAM="" APPLE_KEY="" APPLE_KEY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --invite) INVITE="$(lower "${2:?an email address}")"; shift 2 ;;
    --revoke) REVOKE="$(lower "${2:?an email address}")"; shift 2 ;;
    --remove) REMOVE="$(lower "${2:?an email address}")"; shift 2 ;;
    --stop) STOP="$(lower "${2:?an email address}")"; shift 2 ;;
    --cloud-ai) AI="$(lower "${2:?an email address}")"; AI_ON="${3:?on or off}"; shift 3 ;;
    --invites) LIST=1; shift ;;
    --tidy) TIDY=1; shift ;;
    --test-browser) TESTS=1; shift ;;
    --sign-in-setup) SETUP=1; shift ;;
    --google) GOOGLE="${2:?a client ID, or off}"; shift 2 ;;
    --apple) APPLE="${2:?a Services ID, or off}"; shift 2 ;;
    --apple-team) APPLE_TEAM="${2:?a team ID}"; shift 2 ;;
    --apple-key) APPLE_KEY="${2:?a key ID}"; shift 2 ;;
    --apple-key-file) APPLE_KEY_FILE="${2:?a .p8 file}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
done
EMAIL='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
for e in "$INVITE" "$REVOKE" "$REMOVE" "$STOP" "$AI"; do
  [ -z "$e" ] || [[ "$e" =~ $EMAIL ]] || { echo "Not an email address: $e" >&2; exit 64; }
done
[ -z "$AI" ] || [ "$AI_ON" = on ] || [ "$AI_ON" = off ] || { echo "--cloud-ai <email> on, or off." >&2; exit 64; }
ID='^[A-Za-z0-9._-]+$'
[ -z "$GOOGLE" ] || [ "$GOOGLE" = off ] || [[ "$GOOGLE" =~ $ID ]] || { echo "That doesn't look like a Google client ID." >&2; exit 64; }
if [ -n "$APPLE" ] && [ "$APPLE" != off ]; then
  [ -n "$APPLE_TEAM" ] && [ -n "$APPLE_KEY" ] && [ -n "$APPLE_KEY_FILE" ] \
    || { echo "--apple also needs --apple-team, --apple-key and --apple-key-file." >&2; exit 64; }
  for v in "$APPLE" "$APPLE_TEAM" "$APPLE_KEY"; do [[ "$v" =~ $ID ]] || { echo "Not an Apple ID: $v" >&2; exit 64; }; done
  head -1 "$APPLE_KEY_FILE" 2>/dev/null | grep -q -- "-----BEGIN PRIVATE KEY-----" \
    || { echo "$APPLE_KEY_FILE isn't the AuthKey_….p8 file Apple gave you." >&2; exit 64; }
fi

read -r ACCOUNT CALLER <<<"$(aws sts get-caller-identity --query '[Account, Arn]' --output text)"
PREFIX="auto-applicator-$ACCOUNT"
ARN="arn:$(cut -d: -f2 <<<"$CALLER"):bedrock-agentcore:$AWS_REGION:$ACCOUNT"
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
  if [ "$EXISTS" = 1 ] && [ "$DEPLOYED" = 0 ] && [ -n "$(out BrowserProfileId)" ]; then
    echo "This update replaces the one browser everyone shared with a browser for each person. Its saved cookies go"
    echo "with it: sign in to LinkedIn in the cloud browser once more afterwards (Settings › LinkedIn)."
  fi
  aws cloudformation deploy \
    --stack-name "$STACK" \
    --template-file "$ROOT/infra/cloud-browser.yaml" \
    --parameter-overrides "DomainPrefix=$PREFIX" "GoogleSignIn=$G" "AppleSignIn=$A" "PlaceAttributes=$P" \
      ${AA_HELPER_MODEL:+"HelperModel=$AA_HELPER_MODEL"} \
    --capabilities CAPABILITY_IAM \
    --tags App=auto-applicator \
    --no-fail-on-empty-changeset
  DEPLOYED=1
}

G=false A=false P=false EXISTS=0
if exists; then EXISTS=1 G="$(param GoogleSignIn)" A="$(param AppleSignIn)" P="$(param PlaceAttributes)"; fi
WAS="$G$A"
# Managing people leaves an existing stack as it is.
MANAGE_ONLY=0
if [ -z "$GOOGLE$APPLE" ] && { [ -n "$INVITE$REVOKE$REMOVE$STOP$AI" ] || [ "$LIST$TIDY$TESTS" != 000 ]; }; then MANAGE_ONLY=1; fi
if [ "$EXISTS" = 0 ] || [ "$MANAGE_ONLY" = 0 ]; then deploy; fi
POOL="$(out UserPoolId)"

# ---- A browser and a cookie profile for each person ------------------------------------------------------------
# Both carry the tag person=<the account's permanent ID>, and a sign-in's credentials can only use what carries
# their own (infra/cloud-browser.yaml). The account says which two are theirs (custom:browser, custom:profile), which
# is how the app finds them; changing that gets nobody anywhere, the tag is the lock.
ac() { aws bedrock-agentcore-control "$@"; }
attr() {  # email, attribute → its value, or nothing
  aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$1" \
    --query "UserAttributes[?Name=='$2']|[0].Value" --output text 2>/dev/null | grep -vx None || true
}
attributes() {  # the two account attributes, added to the pool once (CloudFormation can't add them to a pool in use)
  aws cognito-idp describe-user-pool --user-pool-id "$POOL" --query 'UserPool.SchemaAttributes[].Name' --output text \
    | grep -q 'custom:browser' && return 0
  aws cognito-idp add-custom-attributes --user-pool-id "$POOL" --custom-attributes \
    'Name=browser,AttributeDataType=String,Mutable=true,StringAttributeConstraints={MinLength=1,MaxLength=128}' \
    'Name=profile,AttributeDataType=String,Mutable=true,StringAttributeConstraints={MinLength=1,MaxLength=128}'
}
ready() {  # get-browser --browser-id ID, or get-browser-profile --profile-id ID: waits until it can be used
  local i
  for i in $(seq 45); do
    [ "$(ac "$@" --query status --output text 2>/dev/null)" = READY ] && return 0
    sleep 2
  done
  echo "$3 isn't ready yet. Run this again in a minute." >&2
  return 1
}
pair() {  # name, tag value, the browser and profile already known (or nothing) → "browserId profileId", made if missing
  set -e   # (this runs inside $(…), which doesn't inherit it)
  local b="${3:-}" p="${4:-}"
  if [ -z "$b" ] || ! ac get-browser --browser-id "$b" >/dev/null 2>&1; then
    b="$(ac list-browsers --type CUSTOM --query "browserSummaries[?name=='$1']|[0].browserId" --output text)"
    # Application forms hold personal details: nothing is recorded.
    [ "$b" != None ] || b="$(ac create-browser --name "$1" --description "Auto Applicator: one person's Chrome in the cloud." \
      --network-configuration networkMode=PUBLIC --recording enabled=false \
      --tags "App=auto-applicator,person=$2" --query browserId --output text)"
  fi
  if [ -z "$p" ] || ! ac get-browser-profile --profile-id "$p" >/dev/null 2>&1; then
    p="$(ac list-browser-profiles --query "profileSummaries[?name=='$1']|[0].profileId" --output text)"
    [ "$p" != None ] || p="$(ac create-browser-profile --name "$1" \
      --description "Auto Applicator: one person's cookies, kept between their cloud sessions." \
      --tags "App=auto-applicator,person=$2" --query profileId --output text)"
  fi
  ready get-browser --browser-id "$b" >&2
  ready get-browser-profile --profile-id "$p" >&2
  ac tag-resource --resource-arn "$ARN:browser-custom/$b" --tags "App=auto-applicator,person=$2" >&2
  ac tag-resource --resource-arn "$ARN:browser-profile/$p" --tags "App=auto-applicator,person=$2" >&2
  echo "$b $p"
}
place() {  # email, and "revoked" to lock them out: their browser and profile, made if missing, tagged, and recorded
  local sub b p
  sub="$(attr "$1" sub)"
  [ -n "$sub" ] || { echo "$1 has no invitation." >&2; return 1; }
  read -r b p <<<"$(pair "aa_${sub//-/}" "${2:-$sub}" "$(attr "$1" custom:browser)" "$(attr "$1" custom:profile)")"
  [ -n "$b" ] && [ -n "$p" ] || return 1
  aws cognito-idp admin-update-user-attributes --user-pool-id "$POOL" --username "$1" \
    --user-attributes Name=custom:browser,Value="$b" Name=custom:profile,Value="$p"
}
stop_sessions() {  # email → how many running browser sessions of theirs it ended
  local b s n=0
  b="$(attr "$1" custom:browser)"
  if [ -n "$b" ]; then
    for s in $(aws bedrock-agentcore list-browser-sessions --browser-identifier "$b" --status READY \
                 --query 'items[].sessionId' --output text 2>/dev/null || true); do
      aws bedrock-agentcore stop-browser-session --browser-identifier "$b" --session-id "$s" >/dev/null && n=$((n + 1))
    done
  fi
  echo "$n"
}
gone() {  # delete-browser --browser-id ID, or delete-browser-profile --profile-id ID: a session may still be ending
  local i
  for i in $(seq 10); do
    ac "$@" >/dev/null 2>&1 && return 0
    ac "${1/delete/get}" "$2" "$3" >/dev/null 2>&1 || return 0   # already gone
    sleep 3
  done
  echo "Couldn't delete $3. Try --tidy in a minute." >&2
}
people() {  # every account: email, Enabled
  aws cognito-idp list-users --user-pool-id "$POOL" --output text \
    --query 'Users[?UserStatus!=`EXTERNAL_PROVIDER`].[Attributes[?Name==`email`]|[0].Value, Enabled]'
}
# The accounts get their two attributes first; only then can the app client be told it may read them.
if [ "$DEPLOYED" = 1 ] && [ "$P" != true ]; then attributes; P=true; deploy; fi
[ -n "$(out CloudAIGroup)" ] && [ "$P" = true ] || {
  echo "This stack is from before each person had a browser of their own. Update it first: bash scripts/deploy_cloud.sh" >&2
  exit 1
}

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
  "signInProviders": [$PROVIDERS],
  "helperFunction": "$(out HelperFunction)",
  "helperModel": "$(out HelperModel)"
}
JSON
  echo "Wrote Resources/CloudConfig.json (rebuild the app to include it)."
  # Everyone invited before has their own browser and profile (kept as they are when they do).
  attributes
  while IFS=$'\t' read -r email enabled; do
    [ -n "$email" ] || continue
    if [ "$enabled" = True ]; then place "$email"; else place "$email" revoked; fi
  done <<<"$(people)"
fi

OFFERS=""
[ "$G" = true ] && OFFERS="Google"
[ "$A" = true ] && OFFERS="${OFFERS:+$OFFERS or }Apple"
if [ -n "$INVITE" ]; then
  attributes
  STATUS="$(aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$INVITE" --query '[UserStatus, Enabled]' --output text 2>/dev/null || true)"
  case "$STATUS" in
    "")
      aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$INVITE" \
        --user-attributes Name=email,Value="$INVITE" Name=email_verified,Value=true \
        --desired-delivery-mediums EMAIL >/dev/null
      place "$INVITE"
      echo "Invited $INVITE: Cognito emailed a temporary password (valid 7 days)${OFFERS:+; Continue with $OFFERS works for this address too}."
      echo "They get a cloud browser of their own and nothing else in your account." ;;
    *False) aws cognito-idp admin-enable-user --user-pool-id "$POOL" --username "$INVITE"
      place "$INVITE"
      echo "$INVITE can sign in again." ;;
    FORCE_CHANGE_PASSWORD*)
      aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$INVITE" --message-action RESEND \
        --desired-delivery-mediums EMAIL >/dev/null
      place "$INVITE"
      echo "Sent $INVITE's invitation again, with a new temporary password." ;;
    *) place "$INVITE"
      echo "$INVITE already has an account." ;;
  esac
fi
if [ -n "$AI" ]; then
  [ -n "$(attr "$AI" sub)" ] || { echo "$AI has no invitation." >&2; exit 1; }
  if [ "$AI_ON" = on ]; then
    aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --username "$AI" --group-name cloud-ai
    echo "$AI may ask the cloud AI (from their next sign-in, or within the hour)."
  else
    aws cognito-idp admin-remove-user-from-group --user-pool-id "$POOL" --username "$AI" --group-name cloud-ai
    echo "$AI may no longer ask the cloud AI (within the hour)."
  fi
fi
if [ -n "$STOP" ]; then
  echo "Ended $(stop_sessions "$STOP") running browser session(s) of $STOP."
fi
if [ -n "$REVOKE" ]; then
  attributes
  aws cognito-idp admin-disable-user --user-pool-id "$POOL" --username "$REVOKE"
  aws cognito-idp admin-user-global-sign-out --user-pool-id "$POOL" --username "$REVOKE"
  place "$REVOKE" revoked   # the credentials their app still holds (for up to an hour) stop working on their browser now
  echo "Revoked $REVOKE: they can't sign in, their cloud browser is locked, and $(stop_sessions "$REVOKE") running session(s) ended."
  echo "(--invite lets them back in with their cookies as they were; --remove deletes the account and the cookies.)"
fi
if [ -n "$REMOVE" ]; then
  [ -n "$(attr "$REMOVE" sub)" ] || { echo "$REMOVE has no invitation." >&2; exit 1; }
  stop_sessions "$REMOVE" >/dev/null
  B="$(attr "$REMOVE" custom:browser)" P="$(attr "$REMOVE" custom:profile)"
  [ -z "$B" ] || gone delete-browser --browser-id "$B"
  [ -z "$P" ] || gone delete-browser-profile --profile-id "$P"
  aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$REMOVE"
  echo "Removed $REMOVE: the account, its cloud browser and its saved cookies are deleted."
fi
if [ "$TIDY" = 1 ]; then
  # A person's browser and profile are named aa_<their ID>; one whose account is gone has nobody to use it.
  USED="$(aws cognito-idp list-users --user-pool-id "$POOL" --output text \
    --query 'Users[].Attributes[?Name==`custom:browser` || Name==`custom:profile`].Value[]' | tr '\t' '\n')"
  N=0
  while IFS=$'\t' read -r id name; do
    [[ "$name" =~ ^aa_[0-9a-f]{32}$ ]] || continue
    grep -qxF "$id" <<<"$USED" || { gone delete-browser --browser-id "$id"; N=$((N + 1)); }
  done <<<"$(ac list-browsers --type CUSTOM --query 'browserSummaries[].[browserId, name]' --output text)"
  while IFS=$'\t' read -r id name; do
    [[ "$name" =~ ^aa_[0-9a-f]{32}$ ]] || continue
    grep -qxF "$id" <<<"$USED" || { gone delete-browser-profile --profile-id "$id"; N=$((N + 1)); }
  done <<<"$(ac list-browser-profiles --query 'profileSummaries[].[profileId, name]' --output text)"
  echo "Deleted $N browser(s) and cookie profile(s) no account uses."
fi
if [ "$TESTS" = 1 ]; then
  # For `AA_CLOUD_TEST=1 swift test --filter Cloud` with an administrator's credentials. No sign-in can use it: no
  # account's ID is "tests".
  read -r B P <<<"$(pair aa_tests tests)"
  printf '{\n  "browserId": "%s",\n  "browserProfileId": "%s"\n}\n' "$B" "$P" >"$ROOT/Resources/CloudTest.json"
  echo "Wrote Resources/CloudTest.json."
fi
if [ "$LIST" = 1 ]; then
  USERS="$(aws cognito-idp list-users --user-pool-id "$POOL" --output text \
    --query 'Users[?UserStatus!=`EXTERNAL_PROVIDER`].[Attributes[?Name==`email`]|[0].Value, UserStatus, Enabled, Attributes[?Name==`identities`]|[0].Value]')"
  WITH_AI="$(aws cognito-idp list-users-in-group --user-pool-id "$POOL" --group-name cloud-ai --output text \
    --query 'Users[].Attributes[?Name==`email`].Value[]' | tr '\t' '\n')"
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
    grep -qxF "$email" <<<"$WITH_AI" && state="$state; may ask the cloud AI"
    printf '%-36s %s\n' "$email" "$state"
  done <<<"$USERS"
fi
[ -n "$OFFERS" ] || [ "$DEPLOYED" = 0 ] || echo "To offer Google or Apple sign-in: bash scripts/deploy_cloud.sh --sign-in-setup"
[ "$DEPLOYED" = 0 ] || echo "Cloud AI: $(out HelperModel), through the function $(out HelperFunction), for the people you allow it (--cloud-ai <email> on)."
[ "$DEPLOYED" = 0 ] || echo "Resources: https://$AWS_REGION.console.aws.amazon.com/resource-groups/group/auto-applicator"
