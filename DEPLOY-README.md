# Intern Daily Time Attendance — deploy from GitHub to Azure

Everything runs online: GitHub holds the files, a GitHub Action deploys them, Azure Static Web Apps (Free plan) serves the page and the API, and an Azure SQL free-offer database holds the records so every device sees the same data. Nothing is installed on your computer.

## Repository layout

```
index.html                       the whole app
staticwebapp.config.json         routing + Node 20 for the API
deploy-cosmos-interndta.sh       Cosmos DB deployment, with a subscription picker
db-cosmos-interndta.sh           make a clean database and point the site at it
update-azure-interndta.sh        publish changed files to a live site
fix-workflow-azure-interndta.sh  repair GitHub Actions if the Actions tab is empty
api/
  host.json
  package.json                   depends on @azure/cosmos
  shared/cosmos.js               client, database and container bootstrap
  sync/index.js                  POST /api/sync — the records endpoint
  verify/index.js                GET /api/verify?code=SSS-XXXXX-XX (public)
  shorten/index.js               POST /api/shorten — bit.ly, token stays server side
  whoami/index.js                GET /api/whoami — caller IP, no database
  health/index.js                GET /api/health?db=1
legacy-sql/                      the previous Azure SQL API and deploy script, kept for reference
.github/workflows/
  azure-static-web-apps.yml      the deployment workflow
```

## Database structure

One Cosmos DB container, `records`, holds a document per thing, all in the partition `app`:

| Document id | Holds |
| --- | --- |
| `settings` | office, branch, signatory, default required hours |
| `user\|<internId>` | the account: user id, password, name, course, host company, required and adjusted hours, active flag |
| `log\|<internId>\|<YYYY-MM-DD>` | that intern's day: sign-in, break start, break end, sign-out, OT in, OT out, and the device address captured at each punch |
| `login\|<internId>\|<timestamp>` | one sign-in: time, coordinates, accuracy, device address |
| `done\|<internId>` | completion: date, total minutes, certificate code, short link, whether the QR is switched on |

Every document carries `t`, the server timestamp in epoch milliseconds, and `deleted`. A device sends the documents it changed and asks "what has changed since `t`"; the server answers with everything newer. That is what keeps the phones and the admin PC in step, and why deletes are soft — a deleted document still has to reach the other devices.

Because a day is its own document, two people working at once never overwrite each other. If the same intern's same day is edited on two devices, the later save wins.

Nothing needs creating by hand: the API creates the database and container on its first call if the script has not already made them.

## Deployment — Azure Cloud Shell only

Everything runs in the browser. Cloud Shell does the GitHub work with `git` and the Azure work with the CLI. Nothing is installed on your computer, and nothing in these steps can create a billable resource.

### What you need first

A GitHub personal access token, classic, with the **repo** and **workflow** scopes: github.com → Settings → Developer settings → Personal access tokens → Tokens (classic).

### 1. Get the files into Cloud Shell

Azure portal → Cloud Shell (`>_` in the top bar, **Bash**) → **Manage files → Upload** → send the zip, then:

```bash
mkdir -p ~/azure-intern-dta && unzip -o ~/azure-intern-dta.zip -d ~/azure-intern-dta && ls ~/azure-intern-dta
```

### 2. Run the deployment script

```bash
chmod +x ~/azure-intern-dta/deploy-cosmos-interndta.sh
~/azure-intern-dta/deploy-cosmos-interndta.sh
```

It starts by listing your subscriptions with the current one marked, and waits for a number — press Enter to keep the one you are on. Everything after that happens in the subscription you chose.

Then it finds or creates the **free tier** Cosmos DB account, creates `interndta/records` at 400 RU/s, reads the connection string, sets `COSMOS_CONN`, `COSMOS_DB`, `COSMOS_CONTAINER` and `SYNC_KEY` on the Static Web App, removes the old `SQL_CONNECTION_STRING`, pushes the repository, and waits for `/api/health?db=1` to answer green.

It writes `~/azure-interndta-cosmos.txt` with the subscription, account name, database and sync key. Download it and keep it private.

### Staying on the free tier

The free tier gives one Cosmos account per subscription, with the first 1000 RU/s and 25 GB free for the life of the account. The script works inside that and refuses to step outside it:

- It creates the account with `--enable-free-tier true` and then re-reads `enableFreeTier`; if that comes back anything but `true`, it stops rather than leave a billable account running.
- If the subscription has already used its free account, it says so and reuses that account instead of creating a paid second one.
- The container is provisioned at 400 RU/s, well inside the free 1000. Serverless is not used, because the free tier does not apply to it.

An attendance app for a branch is nowhere near 400 RU/s, so the running cost is zero as long as you keep one free account and do not raise the throughput.

### The same steps as individual commands

```bash
# --- pick the subscription ------------------------------------------
az account list --all -o table
az account set --subscription "<name or id>"

# --- settings -------------------------------------------------------
RG=azure-interndta; LOC=southeastasia
SWA=azure-intern-dta
ACCT=azure-interndta-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)
DBNAME=interndta; CONT=records

# --- free tier Cosmos account ---------------------------------------
az group create -n $RG -l $LOC -o none
az cosmosdb create -n $ACCT -g $RG \
  --locations regionName=$LOC failoverPriority=0 isZoneRedundant=False \
  --enable-free-tier true --default-consistency-level Session -o none
az cosmosdb show -n $ACCT -g $RG --query enableFreeTier -o tsv     # must print: true

# --- database and container -----------------------------------------
az cosmosdb sql database create -a $ACCT -g $RG -n $DBNAME -o none
az cosmosdb sql container create -a $ACCT -g $RG -d $DBNAME -n $CONT \
  --partition-key-path "/pk" --throughput 400 -o none

# --- application settings -------------------------------------------
CONN=$(az cosmosdb keys list -n $ACCT -g $RG --type connection-strings \
  --query "connectionStrings[0].connectionString" -o tsv)
SWA_RG=$(az staticwebapp list --query "[?name=='$SWA'].resourceGroup | [0]" -o tsv)
az staticwebapp appsettings set -n $SWA -g $SWA_RG \
  --setting-names COSMOS_CONN="$CONN" COSMOS_DB=$DBNAME COSMOS_CONTAINER=$CONT -o none
az staticwebapp appsettings delete -n $SWA -g $SWA_RG --setting-names SQL_CONNECTION_STRING --yes -o none

# --- publish and check ----------------------------------------------
cd ~/azure-intern-dta && git add -A && git commit -qm "Cosmos API" && git push
HOST=$(az staticwebapp show -n $SWA -g $SWA_RG --query defaultHostname -o tsv)
curl -s "https://$HOST/api/health?db=1"; echo
```

### Moving from the SQL version

The records do not travel across by themselves. The simplest route: sign in on the device that holds the fullest copy — that device uploads everything it has into the empty Cosmos container on its first sync. If the SQL database held days that no device has, export a backup from Settings beforehand and restore it on that device first.

The old API and its deploy script are kept in `legacy-sql/` if you ever need to look back at them.

## Updating a site that is already live

Nothing above needs repeating. Unzip the new files over the repository folder — the `.git` directory and Azure's own workflow survive — then run the update script:

```bash
unzip -o ~/azure-intern-dta.zip -d ~/azure-intern-dta
~/azure-intern-dta/update-azure-interndta.sh
```

It reads `SYNC_KEY` back from the Static Web App and writes it into the new `index.html` (a fresh unzip always arrives with an empty key), removes the bundled workflow so Azure's own one stays in charge, lists what changed, commits, rebases onto the remote and pushes, then waits for `/api/health?db=1`. The Static Web App, SQL server and database are untouched, so records survive.

It asks for the GitHub token, same as the first deployment. If nothing differs it says so and stops without a commit.

For a one-line edit you made yourself in Cloud Shell:

```bash
cd ~/azure-intern-dta && git commit -qam "tweak" && git push
```

After a deployment, hard-refresh the browser — `Ctrl+Shift+R` on a desktop, pull-to-refresh on a phone — or the old page can linger in cache.

### If something needs redoing

| Situation | Command |
| --- | --- |
| Changed a file, want it live | `cd ~/azure-intern-dta && git commit -qam "update" && git push` |
| Lost the sync key | `az staticwebapp appsettings list -n azure-intern-dta -g azure-interndta -o table` |
| Want a clean database | `~/azure-intern-dta/db-azure-interndta.sh` |
| List the servers you have made | `az sql server list -g azure-interndta -o table` |
| Remove an old server | `az sql server delete -g azure-interndta -n <name> --yes` |
| Push rejected, "fetch first" | `cd ~/azure-intern-dta && git pull --rebase origin main && git push origin main` |
| Repo connected to the wrong branch | `az staticwebapp disconnect -n azure-intern-dta -g azure-interndta` then re-run |
| Start over completely | `az group delete -n azure-interndta --yes` and delete the GitHub repo |

## Certificates, codes and the verifier

The certificate is drawn at A4 landscape, 300 dpi (3508 x 2480 px), so **Print** lands on a full A4 sheet with no scaling — choose landscape, margins none — and **Save as image** gives a print-ready PNG.

The layout is fixed: blue and gold ribbons on opposite corners inside a double gold frame, the SSS logo beside the office name with the branch in italic under it, "CERTIFICATE OF / COMPLETION", the gold diamond divider, the intern's name over a gold rule, the body naming the office and branch, the two italic congratulatory lines, the date, the signatory block, and the QR with its code at bottom left.

Four fields in **Settings → Certificate details** fill it in:

| Field | Prints as |
| --- | --- |
| Office name | the header line and the first bold line of the body |
| Branch | the italic line under the office name and the second bold line |
| Signatory name | above the rule at the bottom |
| Signatory position | below it |

The QR always points at the address the app is served from, so certificates made on the live site carry the live link.

### Admin-only: editable PDF and the issue date

Signed in as admin, the certificate dialog gains two things an intern never sees.

**Date issued** — a date picker under the certificate. Changing it rewrites the "Given this …" line, saves against that intern's completion record and syncs, so the same date appears wherever the certificate is produced next.

**Save as editable PDF** — exports A4 landscape with the artwork as the page background and every line of wording as a real form field: office, branch, intern name, the hours line, the training line, the total line, both congratulatory lines, the issue date, and the signatory's name and position. Opened in Acrobat, Edge, Chrome or any PDF form filler, each of those can be clicked and retyped after export, which is useful when a name needs an accent, a title changes, or one certificate needs a wording tweak without regenerating everything.

The fields use Helvetica, so the PDF wording looks slightly different from the PNG, which uses the app's screen fonts. Everything else — ribbons, frame, logo, titles, the QR if you generated one — is part of the background image and is not editable. Save as image and Print still produce the fully flattened version.

Interns get the same button labelled **Save as PDF**, and theirs is flat: the whole certificate is one image in the PDF with no form fields, so nothing on it can be retyped.

### Shorter QR links with Bitly (optional)

With a Bitly token configured, the QR carries a `bit.ly` link instead of the site address, which shrinks a typical certificate QR from a 33 x 33 grid to 25 x 25 — much easier to scan from a printed sheet.

Set the token as an application setting, never in the page:

```bash
read -rsp "Bitly token: " BITLY; echo
az staticwebapp appsettings set -n azure-intern-dta -g azure-interndta \
  --setting-names BITLY_TOKEN="$BITLY" -o none
```

How it behaves:

- The first time **Generate QR code** is pressed for a certificate, the app asks `/api/shorten`, which calls Bitly server-side. The short link is stored on that intern's completion record and synced, so each certificate is shortened once and every later print reuses it.
- The back-half is the certificate code itself, minus the `SSS-` and the dashes: code `SSS-NNGKY-5Q` becomes `https://bit.ly/NNGKY5Q`. The link on the page and the code printed under the QR then match, which is easy to check by eye and easy to type by hand.
- If that back-half is already taken by one of your own links pointing at the same certificate, it is reused rather than treated as an error.
- The token stays in the application setting and is never sent to the browser.

Each step degrades on its own rather than failing:

| What happens | Result |
| --- | --- |
| Custom back-half not allowed on the plan, or already taken by someone else | the ordinary `bit.ly/3xYz…` link, with a toast saying why |
| Token missing, rejected, or monthly allowance spent | the built-in `/v/NNGKY5Q` link, with a toast saying why |
| Bitly unreachable | the built-in link |

To use your own branded domain instead of `bit.ly`, add a `BITLY_DOMAIN` application setting with that domain.

Two things to check on your Bitly plan before relying on this: the monthly link allowance, since each intern's certificate consumes one, and whether custom back-halves are included — on free plans they generally are not, so you would get shortened links with random back-halves rather than the certificate code.

### Codes and scanning

Every completion gets a ten-character code shaped `SSS-XXXXX-XX`: five characters from an alphabet with no look-alikes, plus two checksum characters that reject any single mistyped character. Only the code is printed, centred under the QR.

The certificate is drawn without a QR. Press **Generate QR code** in the preview and it appears at bottom left with the code beneath it, and stays on whatever you save or print afterwards; press it again to take it off. The QR holds a shortened form of the live address, for example `HTTPS://SALMON-GROUND-0DB4A3A00.2.AZURESTATICAPPS.NET/V/NNGKY5Q` — a `/v/` path instead of a query, the code without its dashes, and upper case throughout. That lets the QR use alphanumeric encoding instead of byte encoding, which drops a typical certificate from a 37 x 37 grid to 33 x 33, with visibly chunkier squares at the same printed size. Both the short path and the older `?v=SSS-NNGKY-5Q` form still open the verifier.

Scanning it opens the app on the **Certificate Verifier** with no sign-in needed; it calls `/api/verify` and answers with the intern's name, required hours, hours rendered and completion date, and nothing else. A code can also be typed there by hand, from the **Verify a certificate** button on the sign-in page.

The QR is encoded at error-correction level M with whole-pixel modules, a four-module quiet zone and pure black on white, roughly 33 mm across on the printed sheet. Scan the printed sheet or the saved PNG at full size — the shrunken preview inside the dialog is too small for most scanners, whatever the code says.

## Device addresses

Each punch — sign-in, break start, break end, sign-out, OT in, OT out — asks `/api/whoami` for the device's public IP and stores it against that punch. Sign-ins record one too, next to the location. The admin sees them in the day-correction dialog ("Recorded from: Sign-in 112.204.11.9 · Break start …") and in the **Sign-ins** table.

`/api/whoami` touches no database, so this costs nothing in compute seconds. Without the API configured, punches still record; they simply carry no address. Note that a phone on mobile data shows the carrier's address, not a fixed location, so treat it as a supporting detail rather than proof of presence — and mention the capture in your data privacy notice alongside the location.

## Sessions and idle time

Signing in is the only thing that wakes the database: the sign-in screen itself makes no calls, so a device left sitting on it costs nothing. At sign-in the app pulls fresh accounts first, then checks the password against them, so an intern added on another device can sign in straight away.

After 15 minutes without a tap, key press or scroll, the app signs the person out by itself. Sync stops with it, which lets a serverless database auto-pause instead of being held awake by an idle tab — the main way the free allowance gets burned.

While someone is signed in, anything unsent is retried every minute and the moment the browser reports the connection is back, so punches taken in a dead spot upload on their own. The status line in Settings says "No connection — saved here and sent automatically when the network returns" while that is the case.

## Keeping inside the free allowance

Cosmos DB's free tier covers the first 1000 RU/s and 25 GB on one account per subscription, for the life of the account, and it does not expire. The container runs at 400 RU/s of that.

What this app spends: a sync reads the documents changed since last time and writes the few that the device changed — a handful of request units each. A branch with dozens of interns punching four times a day stays far below 400 RU/s, and the 25 GB is effectively untouchable for text records like these.

Two habits keep it that way:

- Keep one database at 400 RU/s. Each extra container or database you provision takes another slice of the 1000, and `db-cosmos-interndta.sh` prints the commands for listing and deleting old ones.
- Watch the account's **Cost analysis** blade for the first month. It should read zero.

Unlike the serverless SQL version, there is no auto-pause to worry about and no idle-time penalty, so the app no longer has to be careful about when it syncs.

## Security, plainly

`SYNC_KEY` sits in the page source, so anyone who can open the site can call the API and read the records, passwords included. That is acceptable for an internship tracker on a private URL; it is not acceptable for anything confidential.

To tighten it: Static Web App → Settings → Authentication, add Entra ID, restrict routes in `staticwebapp.config.json`, and have `api/sync/index.js` check the `x-ms-client-principal` header instead of the key. Everyone signing in would then need a Microsoft account in your tenant.

## Light and dark

The header carries a moon/sun button that switches the whole app between light and dark. Light is the default; once you pick, that device remembers. The certificate itself is always printed on white.

## Sign-in location

Locations are only captured over https, which the Static Web App provides. Interns see it under the date; the admin sees the latest one on each card and the last 30 under **Sign-ins**. Put a line about it in your programme's data privacy notice.

## Troubleshooting

| What you see | What it usually means |
| --- | --- |
| Action fails on the deployment token | `AZURE_STATIC_WEB_APPS_API_TOKEN` is missing, or was pasted with a trailing space |
| `/api/health` returns 404 | `api_location: "api"` is missing from the workflow, or the `api` folder uploaded without its subfolders |
| `/api/health?db=1` returns an error mentioning COSMOS_CONN | The application setting is missing — run `deploy-cosmos-interndta.sh` again |
| `Entity with the specified id does not exist` | The database or container was deleted; the API recreates them on the next call |
| Free tier error when creating the account | That subscription already has its one free account — the script reuses it; pick another subscription if you want a separate one |
| Settings shows "Offline — saved on this device" | `var SYNC` was never updated in `index.html`, or the key doesn't match the `SYNC_KEY` application setting |
| An intern's punches don't reach the admin | That phone hasn't synced yet; it will on next open. Press **Refresh** on the admin screen to pull |
