# Portfolio Performance API

Ruby API (Sinatra + Puma) that reads a `.portfolio` file (from Google Drive or disk) and returns **balances for cash accounts and securities accounts**. It also includes two utilities: `bin/import` (Fineco) and `bin/sync` (Google Sheets).

Demo file for trials and tests: `test/test.portfolio` (password `portfolio`).

## Setup

```bash
cp env.example .env
bundle install
```

For Drive/Sheets: enable the **Google Drive API** and **Google Sheets API**, create a **service account**, and download the JSON. Share the files with the `…@….iam.gserviceaccount.com` email (Viewer for the API only, **Editor** for import, sync, and tests). Drive returns 404 if the service account has no access.

| Variable | Used by | Description |
| --- | --- | --- |
| `API_KEY` | API | Key in `X-Api-Key`, `Authorization: Bearer`, or `?apikey=` |
| `PORTFOLIO_PASSWORD` | API, Fineco, sync | Password for the encrypted `.portfolio` |
| `PORTFOLIO_GOOGLE_DRIVE_FILE_ID` | API, Fineco, sync | Id (or URL) of the `.portfolio` on Drive |
| `PORTFOLIO_FILE` | local API | Path to a `.portfolio` on disk, if Drive is not configured |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | Drive/Sheets | Service account JSON contents |
| `GOOGLE_APPLICATION_CREDENTIALS` | Drive/Sheets | Alternative: path to the JSON |
| `SYNC_GOOGLE_DRIVE_FILE_ID` | sync | Sync spreadsheet |
| `SYNC_GOOGLE_DRIVE_FILE_ID_TEST` | live tests | Spreadsheet used by sync tests |
| `SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS` | sync | Rows to leave untouched at the top of each sheet. Default `0` |
| `SYNC_GOOGLE_DRIVE_ROWS_CHUNK` | sync | Rows written per Sheets request. Default `100` |
| `SYNC_GOOGLE_DRIVE_PREVIEW_ROWS` | sync | Visible rows per list in the preview. Default `20` |
| `IMPORT_FINECO_XLS_SKIP_LINES` | Fineco | Preamble rows to skip. Default `13`. Override with `--skip-lines` |
| `CACHE_TTL_MINUTES` | API | Default `15` |
| `INCLUDE_RETIRED` | API | Default `true` |
| `PORT` | API | Default `9292` |

## API

Exposes portfolio balances as JSON or CSV. It downloads the `.portfolio` from Drive (or reads `PORTFOLIO_FILE`), decrypts it, computes the balance of each deposit account and the market value of each securities account, and caches the result for `CACHE_TTL_MINUTES` (`?nocache` forces a refresh).

```bash
# Local trial with the demo file, no Drive
API_KEY=dev PORTFOLIO_FILE=test/test.portfolio PORTFOLIO_PASSWORD=portfolio \
  bundle exec puma -C config/puma.rb

curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/health
curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/accounts
curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/accounts.json
curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/accounts.csv
curl -sS "http://127.0.0.1:9292/accounts.csv?apikey=dev&locale=it"
curl -sS -H "X-Api-Key: dev" "http://127.0.0.1:9292/accounts?nocache"
```

`GET /accounts` and `GET /accounts.json` → JSON. `GET /accounts.csv` → UTF-8 CSV, `;` separator (`.` decimals with `locale=en`, `,` with `locale=it`). `GET /health` is public. `GET /` is the same as `/accounts`.

Each row has `kind`: `deposit` (cash) or `securities` (no FX conversion). Securities accounts include `reference_account_uuid`.

Docker:

```bash
docker build -t portfolio-performance-api .
docker run --env-file .env -p 9292:80 portfolio-performance-api
```

## Fineco import

`bin/import fineco` reads a Fineco export (`.xls` / `.xlsx`) and appends new transactions to the Drive `.portfolio` (`PORTFOLIO_GOOGLE_DRIVE_FILE_ID`). It downloads that file into `./import`, copies a backup `name-import-backup-YYYYMMDDTHHMMSS.portfolio`, imports into the downloaded file (not the backup), then uploads only the imported file.

It only proposes Excel rows that are not already in the account. Exact identity is the same SHA-256 as sync (account + date + amount + description + destination + security, matched 1:1). It also skips a row if the account already has the same date and amount (PP's own Fineco PDF/CSV import uses different notes and types), or a buy/sell with the same security and share count within 7 days (trade date vs `Data_Valuta`). `--exclude REGEXP` drops Excel rows **before** that filter if the regexp matches **any column** (case-insensitive). `--skip-lines N` overrides `IMPORT_FINECO_XLS_SKIP_LINES` (default `13`, Fineco EUR preamble). USD exports need `--skip-lines=7`. `Data_Valuta`, `Entrate` → `DEPOSIT`, `Uscite` → `REMOVAL`. The note is `Descrizione Descrizione_Completa Categoria: Moneymap`.

Fineco does not have security / offset-account columns, so those fields are set with regexps that scan **any column** of the current row (case-insensitive), after `--exclude` and before hashing. Both flags share the same `/REGEXP/` or `/REGEXP/VALUE` form and can be repeated (first match wins **per field**; security and offset are independent, so one Excel row can set both):

- If the regexp has a capture group (`(.+?)`, …), the captured text is the value.
- Otherwise the fixed `VALUE` after the last `/` is used.

`--match-security` with no spec defaults to `/Compravendita Titoli\s+(.+?)\s+Qta/`, which matches `Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000` and captures `AMAZON.COM`. The same row can also take a fixed offset account, e.g. `--match-offset-account "/Compravendita Titoli/fineco00109494"`.

The security name and offset account must already exist in the `.portfolio` (by name or UUID). Offset may be a **cash account** (`otherAccount`) or a **securities account** (`portfolio`). Import aborts if they do not.

Portfolio Performance type is chosen after the matchers run:

| Security | Offset | Fineco amount | Type |
| --- | --- | --- | --- |
| no | yes | negative | `CASH_TRANSFER` (Transfer Outbound) |
| no | yes | positive | `CASH_TRANSFER` (Transfer Inbound) |
| yes | no | any | `DEPOSIT` without a security (PP cannot attach a security to a cash deposit; that shows as `<no XEntry>`) |
| yes | yes (securities account) | positive | `SALE` (buy/sell cross-entry) |
| yes | yes (securities account) | negative | `PURCHASE` (buy/sell cross-entry) |
| no | no | Entrate / Uscite | `DEPOSIT` / `REMOVAL` |

Cross-currency transfers (USD↔EUR) keep `CASH_TRANSFER` and add a `GROSS_VALUE` FX unit with `fxRateToBase` (PP cannot open a transfer without the rate). Buy/sell and cash transfers also set `otherUuid` / `otherUpdatedAt` for the counterpart entry; without those PP throws `UnsupportedOperationException` on open. The other-currency amount is taken from the closest existing FX transfer between those two accounts.

Needs an interactive terminal and `bundle install` without `BUNDLE_WITHOUT=utils`. Share the `.portfolio` as **Editor**. Close Portfolio Performance before importing.

```bash
bin/import fineco EUR010069756 ./movements.xlsx
bin/import fineco EUR010069756 --file ~/Desktop/movements.xlsx --exclude "MULTIFUNZIONE CONTACTLESS"
bin/import fineco EUR010069756 test ./movements.xlsx
bin/import fineco "EUR010069756 test" ./movements.xlsx --exclude "compravendita valute"
bin/import fineco USD010069756 import/test_usd.xlsx --skip-lines=7

# Conto USD: titoli → deposito titoli, cambi valuta → conto EUR.
# I due --match-offset-account convivono: per ogni riga vince il primo che matcha.
#
# fineco          provider (oggi l'unico)
# USD010069756    conto PP su cui importare (nome o UUID; qui il conto USD)
# import/test_usd.xlsx
#                 export Fineco .xls/.xlsx (ultimo argomento)
# --skip-lines=7  salta le 7 righe di intestazione Fineco USD
#                 (EUR di solito 13, o IMPORT_FINECO_XLS_SKIP_LINES)
# --match-security "/Compravendita Titoli (.+?) Qta/"
#                 se la riga contiene "Compravendita Titoli AMAZON.COM Qta/...",
#                 il gruppo (.+?) diventa il nome titolo in PP (AMAZON.COM)
# --match-offset-account "/Compravendita Titoli/fineco00109494"
#                 stesse righe titoli: controparte = deposito titoli PP
#                 (niente gruppo → VALUE fisso dopo l'ultimo /)
# --match-offset-account "/Compravendita Divise/EUR010069756"
#                 righe "Compravendita Divise": controparte = conto EUR
#                 → CASH_TRANSFER USD↔EUR
bin/import fineco USD010069756 import/test_usd.xlsx --skip-lines=7 \
  --match-security "/Compravendita Titoli (.+?) Qta/" \
  --match-offset-account "/Compravendita Titoli/fineco00109494" \
  --match-offset-account "/Compravendita Divise/EUR010069756"
```

Account names may contain spaces: quotes are optional. The Excel file can be the last argument or `--file` / `--xls` (easier for tab completion). Everything else before the file is the account name.

Tab completion of `.xls` / `.xlsx` paths is a zsh feature, not Ruby. `bin/import` is often completed as ImageMagick `import`, which does not offer files. Enable the repo completer (after `compinit` in `~/.zshrc`):

```zsh
source ~/projects/ppapi/completions/ppapi.zsh
```

Then `bin/import fineco EUR010069756 --file ~/Desktop/mov<TAB>` lists Excel files. Prefer `~/Desktop/...` over `$HOME/Desktop/...`: zsh expands `~` while completing, not `$HOME`.

Preview shows **EXCLUDED** first (every matching `--exclude` row), then **EXISTING** (already in the portfolio by hash), then **IMPORT**. Each list shows at most 10 rows; arrows scroll all three together. Type labels are the protobuf names that will be written (`CASH_TRANSFER`, not Java `TRANSFER_IN` / `TRANSFER_OUT`). Keys: ↑/↓ one row, `u`/`v` page, **Y** import, **Esc** or **Q** skip. After import, if any rows were not written, the same table shows **DISCARDED** (10 scrollable rows) with the reason in the last column (`matched --exclude`, `already in portfolio`, `security not found: …`). Enter/Q continues. Password: `PORTFOLIO_PASSWORD`. Sample export: `import/test.xlsx`.

## Spreadsheet sync

Aligns transactions both ways for every deposit and securities account in the Drive `.portfolio` (`PORTFOLIO_GOOGLE_DRIVE_FILE_ID`) with a spreadsheet (`SYNC_GOOGLE_DRIVE_FILE_ID`). For each account it prepares two plans, shows the **PORTFOLIO** and **SPREADSHEET** lists, then asks what to write.

Identity: SHA-256 hash of account + date + amount + description + destination + security (recomputed at runtime, not stored). Create-or-update, no deletes. Spreadsheet type wins; the Portfolio Performance UUID is kept. `amount` is a number with `.` decimal (US locale sheet). Writes in chunks of `SYNC_GOOGLE_DRIVE_ROWS_CHUNK` rows.

Share the spreadsheet and `.portfolio` as **Editor**. Close Portfolio Performance before syncing.

```bash
bin/sync
bin/sync cleanup
```

Keys: ↑/↓ one row, `u`/`v` page, **S** spreadsheet only, **P** portfolio only, **B** both, **Esc** or **Q** skip the account. The `.portfolio` is uploaded to Drive once at the end if at least one account chose P or B.

`bin/sync cleanup` clears one sheet at a time (rows above the header and the header stay). Confirm with `y` / `n` / `a` (all remaining sheets), **Esc** = no.

Columns: `date`, `type`, `amount`, `currency`, `description`, `destination`, `uuid`. Sync also writes extra columns (added if missing) that are never used for the identity hash: deposit sheets get `security`, `shares`, `per share`, `offset account`, `note`, `source`; securities sheets get `symbol`, `isin`, `shares`, `quote`, `fees`, `taxes`, `net transaction value`. Empty extra cells are filled from the portfolio; a non-empty sheet cell wins. Securities are looked up (ISIN, then symbol, then name) and never created. `SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS` leaves the first N rows untouched.

`type` must be a protobuf enum from [Portfolio Performance](https://github.com/portfolio-performance/portfolio) (`PURCHASE SALE INBOUND_DELIVERY OUTBOUND_DELIVERY SECURITY_TRANSFER CASH_TRANSFER DEPOSIT REMOVAL DIVIDEND INTEREST INTEREST_CHARGE TAX TAX_REFUND FEE FEE_REFUND`). Java/XML/CSV labels (`BUY`, `FEES`, `TAXES`, `DIVIDENDS`, `TRANSFER_IN`, Compra, Commissioni, …) are remapped to those names. Unknown tokens fall back to `DEPOSIT`/`REMOVAL` from the amount sign. Types that cannot live on that account (for example `FEE` on a securities sheet) are skipped. Buy/sell, cash transfer, and security transfer are written only when PP can load them (`otherUuid`, counterpart account/portfolio, security); otherwise the row is not imported. That avoids `UnsupportedOperationException` on open.

Sheet tabs are named `deposit - {account}` and `securities - {account}` so a cash account and a securities account can share the same Portfolio Performance name.

## Tests

The demo file `test/test.portfolio` (password `portfolio`) is Portfolio Performance’s sample portfolio. Sync tests always use it. Live tests (`test/sync_sheets_test.rb`) empty the `SYNC_GOOGLE_DRIVE_FILE_ID_TEST` spreadsheet, create one sheet per account, and **leave the data** at the end (no cleanup). The spreadsheet must be shared as Editor with the service account.

```bash
# Full suite (live tests are skipped if SYNC_GOOGLE_DRIVE_FILE_ID_TEST is missing)
bundle exec rake test

# In-memory sync only, on the demo file
bundle exec rake test TEST=test/sync_demo_test.rb

# Live sync only, against the test spreadsheet
bundle exec rake test TEST=test/sync_sheets_test.rb
```

Without a complete `.env` the suite still passes: Google tests are skipped.

## Deploy (Kamal)

Needs a VPS with Docker and SSH, and a domain pointing at the server. Images stay on the local registry (`localhost:5555`).

1. In `config/deploy.yml` set the server IP and `proxy.host`.
2. `set -a && source .env && set +a`
3. First setup: `bundle exec kamal setup`
4. Later deploys: `bundle exec kamal deploy`

`kamal-proxy` listens on 80/443, Let’s Encrypt certificate, healthcheck `GET /health`.

```bash
bundle exec kamal logs
bundle exec kamal shell
```
