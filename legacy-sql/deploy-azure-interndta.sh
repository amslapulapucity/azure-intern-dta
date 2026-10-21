#!/bin/bash
# =====================================================================
#  Intern Daily Time Attendance — full deployment from Azure Cloud Shell
#
#  Does everything with the Azure CLI, git and the GitHub REST API:
#    1. creates the GitHub repository
#    2. pushes the app files to it
#    3. creates the Static Web App (Free) wired to that repository
#    4. creates a BRAND NEW free-offer Azure SQL server and database
#    5. sets the application settings
#    6. switches cloud sync on in index.html and pushes again
#    7. waits for the site and checks /api/health?db=1
#
#  A fresh database is created every run and never reused, so the
#  records start empty. The first device that syncs uploads whatever
#  it holds locally. Delete the old server afterwards (the command is
#  printed at the end) — the free offer allows 10 free databases per
#  subscription and old ones keep counting against that.
#
#  Before running:
#    - upload the app files to Cloud Shell and unzip them into AZURE_SRC_DIR
#        mkdir -p ~/azure-intern-dta && unzip -o ~/intern-dta.zip -d ~/azure-intern-dta
#    - have a GitHub personal access token ready, classic, with the
#      "repo" and "workflow" scopes
# =====================================================================
set -uo pipefail

# ---------------------------------------------------------------- settings
AZURE_PREFIX="azure"                                  # goes in front of every name
AZURE_GITHUB_USER="itsmedony"                         # your GitHub account
AZURE_GITHUB_REPO="${AZURE_PREFIX}-intern-dta"        # repository to create or reuse
AZURE_REPO_PRIVATE="true"                             # "false" to make it public
AZURE_BRANCH="main"
AZURE_SRC_DIR="$HOME/${AZURE_PREFIX}-intern-dta"      # where the uploaded files are

AZURE_RG="${AZURE_PREFIX}-interndta"                  # resource group
AZURE_SWA_NAME="${AZURE_PREFIX}-intern-dta"           # Static Web App
AZURE_LOC_SWA="eastasia"                              # Static Web Apps region
AZURE_LOC_SQL="southeastasia"                         # MUST match your other free SQL databases
AZURE_SQL_DB="${AZURE_PREFIX}-interndta-db"           # database name
AZURE_SQL_USER="${AZURE_PREFIX}dtaadmin"              # SQL admin login
AZURE_SQL_TAG="${AZURE_PREFIX}-interndta"             # tag put on every server this script makes
AZURE_OUT_FILE="$HOME/${AZURE_PREFIX}-interndta-settings.txt"

rand() { LC_ALL=C tr -dc "$1" </dev/urandom 2>/dev/null | head -c "$2" || true; }
say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mSTOPPED: %s\033[0m\n' "$*"; exit 1; }

# ---------------------------------------------------------------- 0. checks
say "Checking Cloud Shell, the files and your GitHub token"

az account show --output none 2>/dev/null || die "Azure CLI is not signed in. Run: az login"
echo "   subscription: $(az account show --query name -o tsv)"

[ -d "$AZURE_SRC_DIR" ] || die "$AZURE_SRC_DIR does not exist. Upload and unzip the app files there first."
for f in index.html staticwebapp.config.json api/host.json api/package.json api/sync/index.js; do
  [ -f "$AZURE_SRC_DIR/$f" ] || die "$AZURE_SRC_DIR/$f is missing. Unzip the whole folder, not just index.html."
done
echo "   files found in $AZURE_SRC_DIR"

if [ -z "${AZURE_GITHUB_TOKEN:-}" ]; then
  printf '   GitHub token (repo + workflow scopes, input hidden): '
  read -rs AZURE_GITHUB_TOKEN
  printf '\n'
fi
[ -n "$AZURE_GITHUB_TOKEN" ] || die "No GitHub token supplied."

GH_OK="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token ${AZURE_GITHUB_TOKEN}" https://api.github.com/user)"
[ "$GH_OK" = "200" ] || die "GitHub rejected that token (HTTP $GH_OK). Check the scopes and that it has not expired."
echo "   GitHub token accepted"

# ---------------------------------------------------------------- 1. repository
say "Creating the GitHub repository ${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}"

AZURE_REPO_CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token ${AZURE_GITHUB_TOKEN}" \
  "https://api.github.com/repos/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}")"

if [ "$AZURE_REPO_CODE" = "200" ]; then
  echo "   already exists, reusing it"
else
  AZURE_CREATED="$(curl -s -X POST -H "Authorization: token ${AZURE_GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" https://api.github.com/user/repos \
    -d "{\"name\":\"${AZURE_GITHUB_REPO}\",\"private\":${AZURE_REPO_PRIVATE},\"description\":\"Intern Daily Time Attendance on Azure\"}" \
    | grep -o '"full_name"' | head -1)"
  [ -n "$AZURE_CREATED" ] || die "The repository could not be created. Does the token have the 'repo' scope?"
  echo "   created"
fi

# ---------------------------------------------------------------- 2. push
say "Pushing the app files"

cd "$AZURE_SRC_DIR" || die "cannot enter $AZURE_SRC_DIR"

# Azure writes its own workflow when it connects the repo. Hold mine back for
# this first push so the two cannot collide; if Azure fails to write one (a
# token without the "workflow" scope), fix-workflow-azure-interndta.sh puts
# mine back and wires the deployment token as a repository secret.
mkdir -p /tmp/idta-wf && mv -f .github/workflows/azure-static-web-apps.yml /tmp/idta-wf/ 2>/dev/null || true
rmdir .github/workflows .github 2>/dev/null || true

if [ ! -d .git ]; then
  git init -q
  git checkout -q -b "$AZURE_BRANCH" 2>/dev/null || git branch -M "$AZURE_BRANCH"
fi
git config user.email "${AZURE_GITHUB_USER}@users.noreply.github.com"
git config user.name "$AZURE_GITHUB_USER"

cat > .gitignore <<'IGNORE'
*.zip
azure-interndta-settings.txt
IGNORE

git add -A
git commit -qm "Intern Daily Time Attendance" 2>/dev/null || echo "   nothing new to commit"
git remote remove origin 2>/dev/null || true
git remote add origin "https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"

# The repo may already hold commits — Azure adds its own workflow file when it
# connects the Static Web App. Take those first, then push.
sync_push() {
  if git ls-remote --exit-code --heads origin "$AZURE_BRANCH" >/dev/null 2>&1; then
    git fetch -q origin "$AZURE_BRANCH" || true
    if ! git rebase -q "origin/${AZURE_BRANCH}" 2>/dev/null; then
      git rebase --abort 2>/dev/null || true
      die "the local files and the repository have diverged. Run: cd ${AZURE_SRC_DIR} && git pull --rebase origin ${AZURE_BRANCH} && git push origin ${AZURE_BRANCH}"
    fi
  fi
  git push -q -u origin "$AZURE_BRANCH" || die "git push failed. Check the token's 'repo' scope."
}
sync_push
echo "   pushed to ${AZURE_BRANCH}"

# ---------------------------------------------------------------- 3. static web app
say "Creating the Static Web App (Free plan) in ${AZURE_LOC_SWA}"

az group create --name "$AZURE_RG" --location "$AZURE_LOC_SQL" --output none

AZURE_SWA_RG="$(az staticwebapp list --query "[?name=='${AZURE_SWA_NAME}'].resourceGroup | [0]" -o tsv)"
if [ -n "$AZURE_SWA_RG" ]; then
  echo "   ${AZURE_SWA_NAME} already exists in ${AZURE_SWA_RG}, reusing it"
else
  az staticwebapp create \
    --name "$AZURE_SWA_NAME" --resource-group "$AZURE_RG" --location "$AZURE_LOC_SWA" --sku Free \
    --source "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}" --branch "$AZURE_BRANCH" \
    --token "$AZURE_GITHUB_TOKEN" \
    --app-location "/" --api-location "api" --output-location "" \
    --output none || die "the Static Web App could not be created. Send me the lines above."
  AZURE_SWA_RG="$AZURE_RG"
  echo "   created and connected to the repository"
fi

AZURE_HOST="$(az staticwebapp show --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" --query defaultHostname -o tsv)"
echo "   site: https://${AZURE_HOST}"

# ---------------------------------------------------------------- 4. brand new database
say "Creating a NEW free-offer Azure SQL server and database in ${AZURE_LOC_SQL}"

AZURE_OLD_SERVERS="$(az sql server list --query "[?tags.app=='${AZURE_SQL_TAG}'].name" -o tsv)"
if [ -n "$AZURE_OLD_SERVERS" ]; then
  echo "   note: this script has made these servers before —"
  echo "$AZURE_OLD_SERVERS" | sed 's/^/     /'
  echo "   they are NOT reused. Delete the ones you no longer need; each free"
  echo "   database counts against the 10-per-subscription limit."
fi

AZURE_SQL_PASSWORD="$(rand 'A-Za-z0-9' 20)Aa9"
AZURE_SYNC_KEY="$(rand 'A-Za-z0-9' 40)"
AZURE_SQL_SERVER="${AZURE_PREFIX}-interndta-sql-$(rand 'a-z0-9' 6)"

echo "   creating SQL server ${AZURE_SQL_SERVER} (1 to 2 minutes)"
az sql server create --resource-group "$AZURE_RG" --name "$AZURE_SQL_SERVER" --location "$AZURE_LOC_SQL" \
  --admin-user "$AZURE_SQL_USER" --admin-password "$AZURE_SQL_PASSWORD" \
  --tags app="$AZURE_SQL_TAG" --output none \
  || die "the SQL server could not be created. Send me the lines above."

az sql server firewall-rule create --resource-group "$AZURE_RG" --server "$AZURE_SQL_SERVER" \
  --name AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 \
  --output none 2>/dev/null || true

for TRY in 1 2 3; do
  echo "   creating database ${AZURE_SQL_DB}, attempt ${TRY} of 3 (1 to 3 minutes)"
  az sql db create --resource-group "$AZURE_RG" --server "$AZURE_SQL_SERVER" --name "$AZURE_SQL_DB" \
    --edition GeneralPurpose --family Gen5 --capacity 2 --compute-model Serverless \
    --auto-pause-delay 60 --backup-storage-redundancy Local \
    --use-free-limit --free-limit-exhaustion-behavior AutoPause --yes --output none && break
  [ "$TRY" -lt 3 ] && { echo "   Azure returned an error, waiting 45 seconds"; sleep 45; }
done

AZURE_FREE="$(az sql db show --resource-group "$AZURE_RG" --server "$AZURE_SQL_SERVER" --name "$AZURE_SQL_DB" \
  --query useFreeLimit -o tsv 2>/dev/null)"
[ "$AZURE_FREE" = "true" ] || die "the free database was not created. Either you already have 10 free databases, or ${AZURE_LOC_SQL} is not the region of your first one."
echo "   new free-offer database ready (empty)"

# ---------------------------------------------------------------- 5. app settings
say "Wiring the website to the new database"

AZURE_CONN="Server=tcp:${AZURE_SQL_SERVER}.database.windows.net,1433;Database=${AZURE_SQL_DB};User Id=${AZURE_SQL_USER};Password=${AZURE_SQL_PASSWORD};Encrypt=true;TrustServerCertificate=false;Connection Timeout=60"

az staticwebapp appsettings set --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" \
  --setting-names SQL_CONNECTION_STRING="$AZURE_CONN" SYNC_KEY="$AZURE_SYNC_KEY" --output none \
  || die "the application settings could not be set."
echo "   SQL_CONNECTION_STRING and SYNC_KEY set"

# ---------------------------------------------------------------- 6. switch sync on
say "Turning cloud sync on in index.html and pushing again"

sed -i -E "s#var SYNC = \{ url: \"[^\"]*\", key: \"[^\"]*\" \};#var SYNC = { url: \"/api/sync\", key: \"${AZURE_SYNC_KEY}\" };#" index.html
grep -q "key: \"${AZURE_SYNC_KEY}\"" index.html || die "the SYNC line in index.html was not found. Edit it by hand: var SYNC = { url: \"/api/sync\", key: \"${AZURE_SYNC_KEY}\" };"

git add index.html
git commit -qm "Enable cloud sync" 2>/dev/null || echo "   index.html already carried this key"
sync_push
git remote set-url origin "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"
echo "   pushed, the GitHub Action is deploying"

# ---------------------------------------------------------------- 7. wait and check
say "Waiting for the first deployment (up to 8 minutes)"

AZURE_STATUS="not ready"
for i in $(seq 1 32); do
  AZURE_BODY="$(curl -s --max-time 25 "https://${AZURE_HOST}/api/health?db=1" 2>/dev/null)"
  case "$AZURE_BODY" in
    *'"db":"connected"'*) AZURE_STATUS="healthy"; break ;;
    *'"ok"'*)             AZURE_STATUS="site up, database still waking" ;;
  esac
  sleep 15
done
echo "   $AZURE_STATUS"

# ---------------------------------------------------------------- done
printf 'Intern Daily Time Attendance - deployed %s\n\nWebsite ............ https://%s\nVerifier ........... https://%s/?v=SSS-XXXXX-XX\nHealth check ....... https://%s/api/health?db=1\nRepository ......... https://github.com/%s/%s\n\nSQL server ......... %s.database.windows.net (%s)\nSQL database ....... %s (free offer: %s, created fresh, empty)\nSQL admin user ..... %s\nSQL admin password . %s\nSYNC_KEY ........... %s\n\nFirst sign-in ...... admin / admin123  (change it in Settings straight away)\n\nDelete an older server when you no longer need it:\n  az sql server delete -g %s -n <old-server-name> --yes\n' \
  "$(date)" "$AZURE_HOST" "$AZURE_HOST" "$AZURE_HOST" "$AZURE_GITHUB_USER" "$AZURE_GITHUB_REPO" \
  "$AZURE_SQL_SERVER" "$AZURE_LOC_SQL" "$AZURE_SQL_DB" "$AZURE_FREE" "$AZURE_SQL_USER" \
  "$AZURE_SQL_PASSWORD" "$AZURE_SYNC_KEY" "$AZURE_RG" > "$AZURE_OUT_FILE"
chmod 600 "$AZURE_OUT_FILE"

printf '\n================= DONE =================\n'
cat "$AZURE_OUT_FILE"
printf '========================================\n'
echo "Saved to: $AZURE_OUT_FILE  (Manage files > Download, then keep it private)"
[ "$AZURE_STATUS" = "healthy" ] || echo "If the health check is not green yet, watch the run at https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}/actions"
