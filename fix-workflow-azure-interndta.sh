#!/bin/bash
# =====================================================================
#  Repair the GitHub Actions deployment for an existing Static Web App
#
#  Run this when the Actions tab shows no runs at all. That happens when
#  Azure could not write its own workflow into the repository, usually
#  because the token used at creation time lacked the "workflow" scope.
#
#  It puts a workflow in the repository, stores the Static Web App's
#  deployment token as a repository secret, and pushes — after which
#  every push deploys normally.
#
#    ~/azure-intern-dta/fix-workflow-azure-interndta.sh
# =====================================================================
set -uo pipefail

AZURE_PREFIX="azure"
AZURE_GITHUB_USER="itsmedony"
AZURE_GITHUB_REPO="${AZURE_PREFIX}-intern-dta"
AZURE_BRANCH="main"
AZURE_SRC_DIR="$HOME/${AZURE_PREFIX}-intern-dta"
AZURE_RG="${AZURE_PREFIX}-interndta"
AZURE_SWA_NAME="${AZURE_PREFIX}-intern-dta"

say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mSTOPPED: %s\033[0m\n' "$*"; exit 1; }

cd "$AZURE_SRC_DIR" 2>/dev/null || die "$AZURE_SRC_DIR not found."
[ -f index.html ] || die "index.html is not in $AZURE_SRC_DIR."

if [ -z "${AZURE_GITHUB_TOKEN:-}" ]; then
  printf '   GitHub token (repo + workflow scopes, input hidden): '
  read -rs AZURE_GITHUB_TOKEN
  printf '\n'
fi
[ -n "$AZURE_GITHUB_TOKEN" ] || die "No GitHub token supplied."

# ---------------------------------------------------------------- what is there now
say "Looking at the repository"
AZURE_API="https://api.github.com/repos/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}"
AZURE_WF="$(curl -s -H "Authorization: token ${AZURE_GITHUB_TOKEN}" "${AZURE_API}/actions/workflows" | grep -o '"path": "[^"]*"' | sed 's/.*: "//;s/"//')"
if [ -n "$AZURE_WF" ]; then
  echo "   workflows already registered:"
  echo "$AZURE_WF" | sed 's/^/     /'
else
  echo "   none — that is why nothing deploys"
fi

AZURE_REPO_CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token ${AZURE_GITHUB_TOKEN}" "$AZURE_API")"
[ "$AZURE_REPO_CODE" = "200" ] || die "the repository ${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO} was not found (HTTP $AZURE_REPO_CODE). Run deploy-azure-interndta.sh first, or fix AZURE_GITHUB_REPO at the top of this script."

AZURE_SCOPES="$(curl -sI -H "Authorization: token ${AZURE_GITHUB_TOKEN}" https://api.github.com/user | tr -d '\r' | grep -i '^x-oauth-scopes:' | cut -d' ' -f2-)"
echo "   token scopes: ${AZURE_SCOPES:-unknown}"
case "$AZURE_SCOPES" in
  *workflow*) ;;
  *) die "this token has no 'workflow' scope, so GitHub will reject a workflow file. Make a new classic token with 'repo' and 'workflow' ticked, then run this again." ;;
esac

# ---------------------------------------------------------------- deployment token
say "Reading the deployment token from the Static Web App"
az account show --output none 2>/dev/null || die "Azure CLI is not signed in. Run: az login"
AZURE_SWA_RG="$(az staticwebapp list --query "[?name=='${AZURE_SWA_NAME}'].resourceGroup | [0]" -o tsv)"
[ -n "$AZURE_SWA_RG" ] || die "Static Web App '${AZURE_SWA_NAME}' was not found."
AZURE_DEPLOY_TOKEN="$(az staticwebapp secrets list --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" \
  --query "properties.apiKey" -o tsv)"
[ -n "$AZURE_DEPLOY_TOKEN" ] || die "could not read the deployment token."
echo "   token read (${#AZURE_DEPLOY_TOKEN} characters)"

# ---------------------------------------------------------------- store it as a repo secret
say "Storing it as the repository secret AZURE_STATIC_WEB_APPS_API_TOKEN"
if command -v gh >/dev/null 2>&1; then
  echo "$AZURE_DEPLOY_TOKEN" | GH_TOKEN="$AZURE_GITHUB_TOKEN" gh secret set AZURE_STATIC_WEB_APPS_API_TOKEN \
    --repo "${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}" >/dev/null 2>&1 && AZURE_SECRET_OK=1
fi
if [ -z "${AZURE_SECRET_OK:-}" ]; then
  python3 -c "import nacl" 2>/dev/null || pip install --quiet pynacl 2>/dev/null
  AZURE_KEYJSON="$(curl -s -H "Authorization: token ${AZURE_GITHUB_TOKEN}" "${AZURE_API}/actions/secrets/public-key")"
  AZURE_KEY_ID="$(echo "$AZURE_KEYJSON" | grep -o '"key_id": *"[^"]*"' | sed 's/.*: *"//;s/"//')"
  AZURE_KEY="$(echo "$AZURE_KEYJSON" | grep -o '"key": *"[^"]*"' | sed 's/.*: *"//;s/"//')"
  [ -n "$AZURE_KEY" ] || die "could not read the repository public key."
  AZURE_SEALED="$(SECRET="$AZURE_DEPLOY_TOKEN" KEY="$AZURE_KEY" python3 - <<'PY'
import base64, os
from nacl import public, encoding
pk = public.PublicKey(os.environ["KEY"].encode(), encoding.Base64Encoder())
print(base64.b64encode(public.SealedBox(pk).encrypt(os.environ["SECRET"].encode())).decode())
PY
)"
  [ -n "$AZURE_SEALED" ] || die "could not encrypt the secret. Install the GitHub CLI or pynacl and run this again."
  AZURE_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    -H "Authorization: token ${AZURE_GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "${AZURE_API}/actions/secrets/AZURE_STATIC_WEB_APPS_API_TOKEN" \
    -d "{\"encrypted_value\":\"${AZURE_SEALED}\",\"key_id\":\"${AZURE_KEY_ID}\"}")"
  case "$AZURE_CODE" in 201|204) ;; *) die "GitHub refused the secret (HTTP $AZURE_CODE)." ;; esac
fi
echo "   secret stored"

# ---------------------------------------------------------------- write the workflow
say "Writing .github/workflows/azure-static-web-apps.yml"
mkdir -p .github/workflows
cat > .github/workflows/azure-static-web-apps.yml <<'YML'
name: Deploy Intern Daily Time Attendance

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  build_and_deploy:
    runs-on: ubuntu-latest
    name: Build and deploy
    steps:
      - uses: actions/checkout@v4
      - name: Build and deploy to Azure Static Web Apps
        uses: Azure/static-web-apps-deploy@v1
        with:
          azure_static_web_apps_api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
          action: upload
          app_location: "/"
          api_location: "api"
          output_location: ""
YML

AZURE_REMOTE="https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"
if [ ! -d .git ]; then
  say "This folder has no git history — reconnecting it to the repository"
  git init -q
  git checkout -q -b "$AZURE_BRANCH" 2>/dev/null || git branch -M "$AZURE_BRANCH"
  git remote add origin "$AZURE_REMOTE"
  if git ls-remote --exit-code --heads origin "$AZURE_BRANCH" >/dev/null 2>&1; then
    git fetch -q origin "$AZURE_BRANCH" || die "could not fetch the repository."
    git reset -q --mixed "origin/${AZURE_BRANCH}"     # adopt its history, keep these files
    echo "   reconnected to ${AZURE_BRANCH}"
  else
    echo "   the branch does not exist yet — this push will create it"
  fi
fi

git config user.email "${AZURE_GITHUB_USER}@users.noreply.github.com"
git config user.name "$AZURE_GITHUB_USER"
git remote set-url origin "https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git" 2>/dev/null \
  || git remote add origin "https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"

git add -A
git commit -qm "Add deployment workflow" 2>/dev/null || echo "   nothing new to commit"
git fetch -q origin "$AZURE_BRANCH" 2>/dev/null || true
git rebase -q "origin/${AZURE_BRANCH}" 2>/dev/null || git rebase --abort 2>/dev/null || true
git push -q -u origin "$AZURE_BRANCH" || { git remote set-url origin "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"; die "git push failed."; }
git remote set-url origin "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"
echo "   pushed"

# ---------------------------------------------------------------- watch it
AZURE_HOST="$(az staticwebapp show --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" --query defaultHostname -o tsv)"
say "Waiting for the first run (up to 6 minutes)"
for i in $(seq 1 24); do
  AZURE_BODY="$(curl -s --max-time 25 "https://${AZURE_HOST}/api/health?db=1" 2>/dev/null)"
  case "$AZURE_BODY" in *'"ok"'*) echo "   site answering"; break ;; esac
  sleep 15
done

printf '\nSite ...... https://%s\nActions ... https://github.com/%s/%s/actions\n\n' \
  "$AZURE_HOST" "$AZURE_GITHUB_USER" "$AZURE_GITHUB_REPO"
echo "From now on, update-azure-interndta.sh keeps this workflow in place."
