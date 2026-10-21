#!/bin/bash
# =====================================================================
#  Cosmos DB only — create a clean database and container and point the
#  Static Web App at it. The site, the repository and the Cosmos account
#  are left alone. Use it when you want to start the records fresh.
# =====================================================================
set -uo pipefail

AZURE_PREFIX="azure"
AZURE_RG="${AZURE_PREFIX}-interndta"
AZURE_SWA_NAME="${AZURE_PREFIX}-intern-dta"
AZURE_COSMOS_DB="interndta-$(date +%Y%m%d)"     # a new database each time
AZURE_COSMOS_CONTAINER="records"

say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mSTOPPED: %s\033[0m\n' "$*"; exit 1; }

az account show --output none 2>/dev/null || die "Azure CLI is not signed in. Run: az login"
echo "   subscription: $(az account show --query name -o tsv)"

AZURE_SWA_RG="$(az staticwebapp list --query "[?name=='${AZURE_SWA_NAME}'].resourceGroup | [0]" -o tsv)"
[ -n "$AZURE_SWA_RG" ] || die "Static Web App '${AZURE_SWA_NAME}' was not found in this subscription."

AZURE_COSMOS_ACCT="$(az cosmosdb list --query "[?enableFreeTier].name | [0]" -o tsv)"
[ -n "$AZURE_COSMOS_ACCT" ] && [ "$AZURE_COSMOS_ACCT" != "null" ] || die "no free tier Cosmos account in this subscription. Run deploy-cosmos-interndta.sh first."
AZURE_COSMOS_RG="$(az cosmosdb list --query "[?name=='${AZURE_COSMOS_ACCT}'].resourceGroup | [0]" -o tsv)"

say "Creating ${AZURE_COSMOS_DB} / ${AZURE_COSMOS_CONTAINER} at 400 RU/s in ${AZURE_COSMOS_ACCT}"
az cosmosdb sql database create --account-name "$AZURE_COSMOS_ACCT" --resource-group "$AZURE_COSMOS_RG" \
  --name "$AZURE_COSMOS_DB" --output none 2>/dev/null || echo "   database already there"
az cosmosdb sql container create --account-name "$AZURE_COSMOS_ACCT" --resource-group "$AZURE_COSMOS_RG" \
  --database-name "$AZURE_COSMOS_DB" --name "$AZURE_COSMOS_CONTAINER" \
  --partition-key-path "/pk" --throughput 400 --output none 2>/dev/null || echo "   container already there"

say "Pointing the website at it"
az staticwebapp appsettings set --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" \
  --setting-names COSMOS_DB="$AZURE_COSMOS_DB" COSMOS_CONTAINER="$AZURE_COSMOS_CONTAINER" --output none \
  || die "the application settings could not be set."

AZURE_HOST="$(az staticwebapp show --name "$AZURE_SWA_NAME" --resource-group "$AZURE_SWA_RG" --query defaultHostname -o tsv)"
printf '\nNew empty database: %s / %s\nSite: https://%s\nHealth: https://%s/api/health?db=1\n\n' \
  "$AZURE_COSMOS_DB" "$AZURE_COSMOS_CONTAINER" "$AZURE_HOST" "$AZURE_HOST"
echo "Free tier covers 1000 RU/s in total, so delete old databases you no longer need:"
echo "  az cosmosdb sql database list -a $AZURE_COSMOS_ACCT -g $AZURE_COSMOS_RG -o table"
echo "  az cosmosdb sql database delete -a $AZURE_COSMOS_ACCT -g $AZURE_COSMOS_RG -n <old> --yes"
