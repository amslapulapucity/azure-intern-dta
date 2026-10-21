#!/bin/bash
# =====================================================================
#  Intern Daily Time Attendance — Azure Cosmos DB deployment
#
#  Run this in Azure Cloud Shell (Bash). It:
#    1. lets you pick which Azure subscription to use
#    2. creates (or reuses) a FREE TIER Cosmos DB account
#    3. creates the database and container at 400 RU/s, inside the free
#       1000 RU/s allowance, so the running cost stays zero
#    4. points the Static Web App at it and removes the old SQL setting
#    5. pushes the repository so the new API deploys
#
#  Nothing here can create a billable resource: if the free tier is
#  already used in the chosen subscription, the script says so and
#  offers the existing free account instead of making a paid one.
#
#  Before running:
#    unzip -o ~/azure-intern-dta.zip -d ~/azure-intern-dta
#    ~/azure-intern-dta/deploy-cosmos-interndta.sh
# =====================================================================
set -uo pipefail

AZURE_PREFIX="azure"
AZURE_GITHUB_USER="itsmedony"
AZURE_GITHUB_REPO="${AZURE_PREFIX}-intern-dta"
AZURE_BRANCH="main"
AZURE_SRC_DIR="$HOME/${AZURE_PREFIX}-intern-dta"

AZURE_RG="${AZURE_PREFIX}-interndta"
AZURE_SWA_NAME="${AZURE_PREFIX}-intern-dta"
AZURE_LOC="southeastasia"                      # Cosmos account region
AZURE_COSMOS_DB="interndta"
AZURE_COSMOS_CONTAINER="records"
AZURE_OUT_FILE="$HOME/${AZURE_PREFIX}-interndta-cosmos.txt"

rand() { LC_ALL=C tr -dc "$1" </dev/urandom 2>/dev/null | head -c "$2" || true; }
say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mSTOPPED: %s\033[0m\n' "$*"; exit 1; }

# ---------------------------------------------------------------- 1. subscription
say "Choose the subscription"
az account show --output none 2>/dev/null || die "Azure CLI is not signed in. Run: az login"

SUB_IDS=(); SUB_NAMES=(); SUB_STATES=()
while IFS=$'\t' read -r sname sid sstate; do
  SUB_NAMES+=("$sname"); SUB_IDS+=("$sid"); SUB_STATES+=("$sstate")
done < <(az account list --all --query "[].[name,id,state]" -o tsv)

[ "${#SUB_IDS[@]}" -gt 0 ] || die "no subscriptions found for this account."

CURRENT="$(az account show --query id -o tsv)"
for i in "${!SUB_IDS[@]}"; do
  MARK=" "; [ "${SUB_IDS[$i]}" = "$CURRENT" ] && MARK="*"
  printf '  %s %2d) %-45s %s  %s\n' "$MARK" "$((i+1))" "${SUB_NAMES[$i]}" "${SUB_IDS[$i]}" "${SUB_STATES[$i]}"
done
echo "   (* = the one currently selected)"
printf '   Number to use [Enter keeps the current one]: '
read -r PICK
if [ -n "$PICK" ]; then
  IDX=$((PICK-1))
  [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#SUB_IDS[@]}" ] || die "there is no option $PICK."
  az account set --subscription "${SUB_IDS[$IDX]}" || die "could not switch subscription."
fi
SUB_ID="$(az account show --query id -o tsv)"
SUB_NAME="$(az account show --query name -o tsv)"
echo "   using: $SUB_NAME"

# ---------------------------------------------------------------- 2. checks
say "Checking the folder, the Static Web App and your GitHub token"
[ -f "$AZURE_SRC_DIR/index.html" ] || die "$AZURE_SRC_DIR/index.html is missing. Unzip the files there first."
[ -f "$AZURE_SRC_DIR/api/shared/cosmos.js" ] || die "$AZURE_SRC_DIR/api/shared/cosmos.js is missing — unzip the Cosmos version."
cd "$AZURE_SRC_DIR" || die "cannot enter $AZURE_SRC_DIR"

AZURE_SWA_RG="$(az staticwebapp list --query "[?name=='${AZURE_SWA_NAME}'].resourceGroup | [0]" -o tsv)"
[ -n "$AZURE_SWA_RG" ] || die "Static Web App '${AZURE_SWA_NAME}' was not found in this subscription. Pick the subscription that holds it, or run deploy-azure-interndta.sh first."
AZURE_HOST="$(az staticwebapp show --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" --query defaultHostname -o tsv)"
echo "   site: https://${AZURE_HOST}"

if [ -z "${AZURE_GITHUB_TOKEN:-}" ]; then
  printf '   GitHub token (repo + workflow scopes, input hidden): '
  read -rs AZURE_GITHUB_TOKEN
  printf '\n'
fi
[ -n "$AZURE_GITHUB_TOKEN" ] || die "No GitHub token supplied."

az group create --name "$AZURE_RG" --location "$AZURE_LOC" --output none

# ---------------------------------------------------------------- 3. free tier account
say "Finding or creating the free tier Cosmos DB account"

AZURE_FREE_ACCT="$(az cosmosdb list --query "[?enableFreeTier].name | [0]" -o tsv 2>/dev/null)"
if [ -n "$AZURE_FREE_ACCT" ] && [ "$AZURE_FREE_ACCT" != "null" ]; then
  AZURE_COSMOS_ACCT="$AZURE_FREE_ACCT"
  AZURE_COSMOS_RG="$(az cosmosdb list --query "[?name=='${AZURE_COSMOS_ACCT}'].resourceGroup | [0]" -o tsv)"
  echo "   this subscription already has its one free tier account: ${AZURE_COSMOS_ACCT}"
  echo "   reusing it — a second free account is not allowed, and making a paid one is not what you asked for"
else
  AZURE_COSMOS_ACCT="${AZURE_PREFIX}-interndta-$(rand 'a-z0-9' 6)"
  AZURE_COSMOS_RG="$AZURE_RG"
  echo "   creating ${AZURE_COSMOS_ACCT} with the free tier discount (5 to 10 minutes)"
  az cosmosdb create --name "$AZURE_COSMOS_ACCT" --resource-group "$AZURE_COSMOS_RG" \
    --locations regionName="$AZURE_LOC" failoverPriority=0 isZoneRedundant=False \
    --enable-free-tier true --default-consistency-level Session \
    --output none || die "the Cosmos account could not be created. If the error mentions the free tier, this subscription has already used it elsewhere."
fi

AZURE_IS_FREE="$(az cosmosdb show --name "$AZURE_COSMOS_ACCT" --resource-group "$AZURE_COSMOS_RG" --query enableFreeTier -o tsv)"
[ "$AZURE_IS_FREE" = "true" ] || die "${AZURE_COSMOS_ACCT} is not a free tier account. Stopping rather than running up a bill."

# ---------------------------------------------------------------- 4. database and container
say "Creating the database and container at 400 RU/s"

az cosmosdb sql database create --account-name "$AZURE_COSMOS_ACCT" --resource-group "$AZURE_COSMOS_RG" \
  --name "$AZURE_COSMOS_DB" --output none 2>/dev/null || echo "   database already there"

az cosmosdb sql container create --account-name "$AZURE_COSMOS_ACCT" --resource-group "$AZURE_COSMOS_RG" \
  --database-name "$AZURE_COSMOS_DB" --name "$AZURE_COSMOS_CONTAINER" \
  --partition-key-path "/pk" --throughput 400 --output none 2>/dev/null || echo "   container already there"

AZURE_RU="$(az cosmosdb sql container throughput show --account-name "$AZURE_COSMOS_ACCT" \
  --resource-group "$AZURE_COSMOS_RG" --database-name "$AZURE_COSMOS_DB" \
  --name "$AZURE_COSMOS_CONTAINER" --query "resource.throughput" -o tsv 2>/dev/null)"
echo "   throughput: ${AZURE_RU:-unknown} RU/s of the 1000 RU/s that are free"

# ---------------------------------------------------------------- 5. app settings
say "Pointing the website at Cosmos DB"

AZURE_CONN="$(az cosmosdb keys list --name "$AZURE_COSMOS_ACCT" --resource-group "$AZURE_COSMOS_RG" \
  --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)"
[ -n "$AZURE_CONN" ] || die "could not read the Cosmos connection string."

AZURE_SYNC_KEY="$(az staticwebapp appsettings list --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" \
  --query "properties.SYNC_KEY" -o tsv 2>/dev/null)"
if [ -z "$AZURE_SYNC_KEY" ] || [ "$AZURE_SYNC_KEY" = "null" ]; then
  AZURE_SYNC_KEY="$(rand 'A-Za-z0-9' 40)"
  echo "   no SYNC_KEY was set — generating one"
else
  echo "   keeping the existing SYNC_KEY, so index.html needs no change"
fi

az staticwebapp appsettings set --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" \
  --setting-names COSMOS_CONN="$AZURE_CONN" COSMOS_DB="$AZURE_COSMOS_DB" \
                  COSMOS_CONTAINER="$AZURE_COSMOS_CONTAINER" SYNC_KEY="$AZURE_SYNC_KEY" \
  --output none || die "the application settings could not be set."

az staticwebapp appsettings delete --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" \
  --setting-names SQL_CONNECTION_STRING --yes --output none 2>/dev/null || true
echo "   COSMOS_CONN, COSMOS_DB, COSMOS_CONTAINER and SYNC_KEY set; the old SQL setting removed"

# ---------------------------------------------------------------- 6. publish
say "Publishing the Cosmos version of the API"

sed -i -E "s#var SYNC = \{ url: \"[^\"]*\", key: \"[^\"]*\" \};#var SYNC = { url: \"/api/sync\", key: \"${AZURE_SYNC_KEY}\" };#" index.html

if ls .github/workflows/azure-static-web-apps-*.yml >/dev/null 2>&1; then
  rm -f .github/workflows/azure-static-web-apps.yml
fi

if [ ! -d .git ]; then
  git init -q
  git checkout -q -b "$AZURE_BRANCH" 2>/dev/null || git branch -M "$AZURE_BRANCH"
  git remote add origin "https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"
  if git ls-remote --exit-code --heads origin "$AZURE_BRANCH" >/dev/null 2>&1; then
    git fetch -q origin "$AZURE_BRANCH" && git reset -q --mixed "origin/${AZURE_BRANCH}"
  fi
fi
git config user.email "${AZURE_GITHUB_USER}@users.noreply.github.com"
git config user.name "$AZURE_GITHUB_USER"
git remote set-url origin "https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git" 2>/dev/null \
  || git remote add origin "https://${AZURE_GITHUB_USER}:${AZURE_GITHUB_TOKEN}@github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"

git add -A
if git diff --cached --quiet; then
  echo "   the repository already matches these files"
else
  git commit -qm "Move the API to Azure Cosmos DB"
  git fetch -q origin "$AZURE_BRANCH" 2>/dev/null || true
  git rebase -q "origin/${AZURE_BRANCH}" 2>/dev/null || git rebase --abort 2>/dev/null || true
  git push -q -u origin "$AZURE_BRANCH" || { git remote set-url origin "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"; die "git push failed. Check the token's 'repo' scope."; }
  echo "   pushed — the GitHub Action is deploying"
fi
git remote set-url origin "https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}.git"

# ---------------------------------------------------------------- 7. wait
say "Waiting for the new API (up to 8 minutes)"
AZURE_STATUS="not ready"
for i in $(seq 1 32); do
  AZURE_BODY="$(curl -s --max-time 25 "https://${AZURE_HOST}/api/health?db=1" 2>/dev/null)"
  case "$AZURE_BODY" in
    *'"db":"connected"'*) AZURE_STATUS="healthy"; break ;;
    *'"ok"'*)             AZURE_STATUS="site up, API still starting" ;;
  esac
  sleep 15
done
echo "   $AZURE_STATUS"

printf 'Intern Daily Time Attendance on Cosmos DB - %s\n\nSubscription ....... %s (%s)\nWebsite ............ https://%s\nHealth check ....... https://%s/api/health?db=1\nCosmos account ..... %s (free tier: %s)\nDatabase ........... %s / %s at %s RU/s\nSYNC_KEY ........... %s\n\nRecords live in Cosmos now. The first device to sign in uploads whatever\nit holds locally, so sign in first on the device with the fullest records.\n' \
  "$(date)" "$SUB_NAME" "$SUB_ID" "$AZURE_HOST" "$AZURE_HOST" \
  "$AZURE_COSMOS_ACCT" "$AZURE_IS_FREE" "$AZURE_COSMOS_DB" "$AZURE_COSMOS_CONTAINER" "${AZURE_RU:-400}" \
  "$AZURE_SYNC_KEY" > "$AZURE_OUT_FILE"
chmod 600 "$AZURE_OUT_FILE"

printf '\n================= DONE =================\n'; cat "$AZURE_OUT_FILE"; printf '========================================\n'
echo "Saved to: $AZURE_OUT_FILE  (Manage files > Download, then keep it private)"
[ "$AZURE_STATUS" = "healthy" ] || echo "If the health check is not green yet, watch https://github.com/${AZURE_GITHUB_USER}/${AZURE_GITHUB_REPO}/actions"
