#!/bin/bash
# =====================================================================
#  Intern Daily Time Attendance — update an already deployed site
#
#  For when the site, the repository and the database already exist and
#  you only want to push new files. It does NOT touch the Static Web
#  App, the SQL server or the database.
#
#    1. reads SYNC_KEY back from the Static Web App
#    2. writes that key into the new index.html
#    3. drops the bundled workflow file so Azure's own one stays in charge
#    4. commits, rebases onto the remote and pushes
#    5. waits for the deployment and checks /api/health?db=1
#
#  Typical use — unzip the new files straight over the repository folder
#  so the .git directory and Azure's workflow survive:
#
#    unzip -o ~/azure-intern-dta.zip -d ~/azure-intern-dta
#    ~/azure-intern-dta/update-azure-interndta.sh
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

# ---------------------------------------------------------------- 0. checks
say "Checking the folder and your GitHub token"
[ -f "$AZURE_SRC_DIR/index.html" ] || die "$AZURE_SRC_DIR/index.html is missing. Unzip the new files there first."
cd "$AZURE_SRC_DIR" || die "cannot enter $AZURE_SRC_DIR"

if [ -z "${AZURE_GITHUB_TOKEN:-}" ]; then
  printf '   GitHub token (repo + workflow scopes, input hidden): '
  read -rs AZURE_GITHUB_TOKEN
  printf '\n'
fi
[ -n "$AZURE_GITHUB_TOKEN" ] || die "No GitHub token supplied."

# ---------------------------------------------------------------- 1. the key
say "Reading SYNC_KEY from the Static Web App"
AZURE_SYNC_KEY=""
if az account show --output none 2>/dev/null; then
  AZURE_SWA_RG="$(az staticwebapp list --query "[?name=='${AZURE_SWA_NAME}'].resourceGroup | [0]" -o tsv)"
  if [ -n "$AZURE_SWA_RG" ]; then
    AZURE_SYNC_KEY="$(az staticwebapp appsettings list --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" \
      --query "properties.SYNC_KEY" -o tsv 2>/dev/null)"
    AZURE_HOST="$(az staticwebapp show --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" --query defaultHostname -o tsv)"
  fi
fi
if [ -z "$AZURE_SYNC_KEY" ] || [ "$AZURE_SYNC_KEY" = "null" ]; then
  # fall back to the key already committed in the repository
  AZURE_SYNC_KEY="$(git show "origin/${AZURE_BRANCH}:index.html" 2>/dev/null | grep -o 'key: "[A-Za-z0-9]*"' | head -1 | cut -d'"' -f2)"
fi
[ -n "$AZURE_SYNC_KEY" ] && echo "   key found (${#AZURE_SYNC_KEY} characters)" || echo "   no key found — cloud sync will stay off until you set it"

# ---------------------------------------------------------------- 2. prepare the files
say "Preparing the files"
# Keep exactly one workflow. If Azure generated its own when the Static Web App
# was created, drop the bundled one; otherwise the bundled one is what deploys.
if ls .github/workflows/azure-static-web-apps-*.yml >/dev/null 2>&1; then
  rm -f .github/workflows/azure-static-web-apps.yml
  echo "   using Azure's own workflow"
else
  echo "   using the bundled workflow (needs the AZURE_STATIC_WEB_APPS_API_TOKEN secret)"
fi

if [ -n "$AZURE_SYNC_KEY" ]; then
  sed -i -E "s#var SYNC = \{ url: \"[^\"]*\", key: \"[^\"]*\" \};#var SYNC = { url: \"/api/sync\", key: \"${AZURE_SYNC_KEY}\" };#" index.html
  grep -q "key: \"${AZURE_SYNC_KEY}\"" index.html || die "the SYNC line in index.html was not found."
  echo "   cloud sync key written into index.html"
fi

if [ ! -d .git ]; then
  say "This folder has no git history — reconnecting it to the repository"
  git init -q
  git checkout -q -b "$AZURE_BRANCH" 2>/dev/null || git branch -M "$AZURE_BRANCH"
  git remote add origin "https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"
  git fetch -q origin "$AZURE_BRANCH" || die "could not fetch the repository. Check the token and the repository name."
  git reset -q --mixed "origin/${AZURE_BRANCH}"
fi

git config user.email "${AZURE_GITHUB_USER}@users.noreply.github.com"
git config user.name "$AZURE_GITHUB_USER"
git remote set-url origin "https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git" 2>/dev/null \
  || git remote add origin "https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"

# ---------------------------------------------------------------- 3. what changed
say "Changes to publish"
git add -A
if git diff --cached --quiet; then
  echo "   nothing changed — the repository already matches these files"
  git remote set-url origin "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"
  exit 0
fi
git diff --cached --name-status | sed 's/^/   /'

# ---------------------------------------------------------------- 4. push
say "Publishing"
git commit -qm "Update $(date '+%Y-%m-%d %H:%M')"
git fetch -q origin "$AZURE_BRANCH" || true
if ! git rebase -q "origin/${AZURE_BRANCH}" 2>/dev/null; then
  git rebase --abort 2>/dev/null || true
  git remote set-url origin "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"
  die "the local files and the repository have diverged. Run: cd ${AZURE_SRC_DIR} && git pull --rebase origin ${AZURE_BRANCH} && git push origin ${AZURE_BRANCH}"
fi
git push -q origin "$AZURE_BRANCH" || { git remote set-url origin "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"; die "git push failed. Check the token's 'repo' scope."; }
git remote set-url origin "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"
echo "   pushed — the GitHub Action is deploying"

# ---------------------------------------------------------------- 5. wait
if [ -n "${AZURE_HOST:-}" ]; then
  say "Waiting for the new version (up to 6 minutes)"
  AZURE_STATUS="not ready"
  for i in $(seq 1 24); do
    AZURE_BODY="$(curl -s --max-time 25 "https://${AZURE_HOST}/api/health?db=1" 2>/dev/null)"
    case "$AZURE_BODY" in
      *'"db":"connected"'*) AZURE_STATUS="healthy"; break ;;
      *'"ok"'*)             AZURE_STATUS="site up, database still waking" ;;
    esac
    sleep 15
  done
  echo "   $AZURE_STATUS"
  printf '\nSite ...... https://%s\nActions ... https://github.com/%s/%s/actions\n\n' \
    "$AZURE_HOST" "$AZURE_GITHUB_USER" "$AZURE_GITHUB_REPO"
else
  printf '\nPushed. Watch the run at https://github.com/%s/%s/actions\n\n' "$AZURE_GITHUB_USER" "$AZURE_GITHUB_REPO"
fi

echo "Tip: hard-refresh the site (Ctrl+Shift+R, or pull down to refresh on a phone) to clear the old page from the browser cache."
