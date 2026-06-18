# Dropbox Sync

Upload your Home Assistant backups (and optionally files from `/share`) to
Dropbox.

This add-on is built locally by the Home Assistant Supervisor from the source
in this directory — there is no published Docker image. First install takes a
couple of minutes; subsequent updates are fast.

## What changed in 2.1.0

You no longer need to run a separate Python script to mint a refresh token.
The add-on does the OAuth code exchange itself: paste a one-time auth code
into the Configuration tab and the add-on stores the long-lived
`refresh_token` in `/data/refresh_token`. Set-up is now fully inside the
Home Assistant UI.

The `refresh_token` field is still accepted (legacy compatibility), but you
do not need it for new installs.

## One-time setup

### 1. Create a Dropbox app

Go to <https://www.dropbox.com/developers/apps> and click **Create app**.

- **API:** Scoped access
- **Access type:** App folder (recommended — keeps the add-on sandboxed
  to one folder) or Full Dropbox
- **Name:** anything you like

### 2. Grant permissions (easy to miss)

On the new app's page, click the **Permissions** tab and enable at minimum:

- `files.content.write`
- `files.content.read`

Then scroll to the bottom and click **Submit**. *Toggling the checkboxes is
not enough — without the Submit click, the permissions are not granted.*

### 3. Copy the app key and app secret

On the **Settings** tab, copy:

- **App key**
- **App secret** (click *Show* next to it)

**Do not** click the "Generated access token" button. That gives you a
short-lived access token, not the refresh token this add-on needs.

### 4. Install and start the add-on

Install Dropbox Sync, paste `app_key` and `app_secret` into the
Configuration tab, leave `auth_code` blank for now, and start the add-on.

The add-on's log will print a Dropbox authorization URL that already has
your `app_key` and the `token_access_type=offline` parameter baked in,
under a "No Dropbox authorization on file" message.

### 5. Authorize and paste the auth code

- Open the URL from the log in a browser, log in to Dropbox if asked,
  and click **Continue** then **Allow**.
- Dropbox shows you a one-time **authorization code**. Copy it.
- Go back to the add-on's Configuration tab, paste the code into the
  `auth_code` field, click **Save**, and restart the add-on.

On startup, the add-on exchanges the code for a long-lived `refresh_token`,
saves it to `/data/refresh_token`, and from then on ignores `auth_code` on
every restart. You can clear the `auth_code` field at your convenience —
the code is single-use and useless after exchange anyway.

When auth succeeds, the log will show:

```
[Info] refresh_token cached in add-on persistent storage.
[Info]   Account: Your Name <you@example.com>
[Info] Authentication OK.
[Info] Listening for messages via stdin service call...
```

## Usage

Trigger an upload via the `hassio.addon_stdin` service from an automation
or from Developer Tools → Services:

```yaml
service: hassio.addon_stdin
data:
  addon: local_dropbox_sync
  input:
    command: upload
```

(The slug is `local_dropbox_sync` when the Supervisor builds the add-on
locally from this repo.)

## Configuration reference

| Option | Required | Notes |
|---|---|---|
| `app_key` | yes | App key from your Dropbox app's Settings tab. |
| `app_secret` | yes | App secret from your Dropbox app's Settings tab. |
| `auth_code` | once | One-time authorization code, used only on first start (or to re-authorize). After exchange, the add-on remembers it and won't re-exchange the same code. |
| `output` | yes | Path inside Dropbox where backups land, relative to the app's scope. `/` means the app folder root. |
| `display_path` | no | Cosmetic. The path prefix as you see it in your real Dropbox (e.g. `/Apps/<your app folder name>`). When set, the startup banner and each upload log line show the full Dropbox-visible path. App-folder apps can't auto-discover this — the API isn't allowed to see outside the app's sandbox. |
| `keep_last` | no | If set, after each upload run, prune **Supervisor-local** backups so only the N newest survive. Does NOT touch Dropbox. |
| `dropbox_keep_last` | no | If set, after each upload run, prune **Dropbox** so only the N newest `*.tar` files in `output` survive. Independent of `keep_last`. Set both to the same value for true mirror mode. Only `*.tar` files are pruned, so `filetypes` uploads from `/share` are not touched. |
| `filetypes` | no | Pipe-separated extensions (e.g. `jpg\|png`) — if set, also uploads matching files under `/share` on each run. |
| `debug` | no | Default `false`. When `true`, prints the underlying uploader script's bash xtrace (`+ curl ...` lines for every chunk upload) into the add-on log. Useful only when diagnosing an upload failure no other log lines explain. |
| `refresh_token` | no | Legacy: if set and there's no cached refresh_token yet, the add-on adopts this value. New installs don't need it. |

## Re-authorizing

If you ever revoke the app's access, rotate the app secret, or otherwise
need a fresh refresh token, repeat steps 4–5: paste a new auth code into
`auth_code`, restart. The new refresh token replaces the cached one.

## Alternate: external `get_refresh_token.py` helper

If you'd rather mint the refresh token on a laptop instead of pasting an
auth code into the add-on, this directory still ships a standalone helper:

```sh
python3 dropbox-sync/get_refresh_token.py
```

It does the same OAuth dance and prints a `refresh_token`. Paste that into
the `refresh_token` legacy field (or write it directly to
`/data/refresh_token` if you have shell access).

## Notes

- The Dropbox uploader script (`dropbox_uploader.sh`) is pinned to a
  specific commit at image build time so a future upstream change cannot
  silently break this add-on.
- `keep_last` uses the current Supervisor backups API (`/backups`), not
  the legacy `/snapshots` endpoint.
