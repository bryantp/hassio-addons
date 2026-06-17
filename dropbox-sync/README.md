# Dropbox Sync

Upload your Home Assistant backups (and optionally files from `/share`) to
Dropbox.

This add-on is built locally by the Home Assistant Supervisor from the source
in this directory — there is no published Docker image. First install takes a
couple of minutes; subsequent updates are fast.

## What changed in 2.0.0

Dropbox shut down API v1 in 2017 and stopped issuing long-lived access tokens
shortly after, which is why the 1.x add-on stopped working. 2.0.0 uses Dropbox
API v2 with the modern refresh-token OAuth flow.

The configuration schema changed. You now provide an `app_key`, `app_secret`,
and `refresh_token` instead of a single `oauth_access_token`. See below.

## One-time setup

### 1. Create a Dropbox app

Go to <https://www.dropbox.com/developers/apps> and click **Create app**.

- **API:** Scoped access
- **Access type:** App folder (recommended — keeps the add-on sandboxed
  to a single folder) or Full Dropbox if you prefer
- **Name:** anything you like

On the new app's page:

- Under **Permissions**, enable at minimum `files.content.write` and
  `files.content.read`. Click **Submit**.
- Under **Settings**, copy the **App key** and **App secret**.

### 2. Generate a refresh token

On any machine with Python 3 and a browser:

```sh
python3 dropbox-sync/get_refresh_token.py
```

Paste the app key and secret when prompted. Your browser opens to a Dropbox
authorization page; approve it and copy the authorization code back into the
terminal. The script prints your `refresh_token`.

### 3. Configure the add-on

In the add-on's Configuration tab:

```yaml
app_key: "<your app key>"
app_secret: "<your app secret>"
refresh_token: "<the refresh token from step 2>"
output: "/"            # path inside Dropbox; "/" means the app folder root
keep_last: 5           # optional: prune backups to the N newest
filetypes: "jpg|png"   # optional: also upload matching files from /share
```

Restart the add-on.

## Usage

The add-on listens on stdin for service calls. To trigger an upload, call the
`hassio.addon_stdin` service from an automation:

```yaml
service: hassio.addon_stdin
data:
  addon: local_dropbox_sync
  input:
    command: upload
```

(The slug is `local_dropbox_sync` when the Supervisor builds it locally from
this repo.)

## Notes

- The Dropbox uploader script (`dropbox_uploader.sh`) is pinned to a specific
  commit at image build time so a future upstream change cannot silently break
  this add-on the way it did before.
- `keep_last` uses the current Supervisor backups API (`/backups`), not the
  legacy `/snapshots` endpoint.
