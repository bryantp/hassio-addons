# Changelog

## 2.3.0

- **Added** `dropbox_keep_last` config option. After each upload run, prunes oldest `*.tar` files from Dropbox so only the N newest survive. Independent of `keep_last` (Supervisor side) — set both to the same value for mirror mode, or asymmetric values (e.g. `keep_last: 3, dropbox_keep_last: 30`) for "thin local, deep cloud" retention. Only `*.tar` files are touched, so `filetypes` uploads from `/share` are unaffected.

## 2.2.0

- **Added** `display_path` config option. When set to the Dropbox-visible path prefix (e.g. `/Apps/<your app folder name>`), the startup banner and each upload log line show the full Dropbox-visible path instead of the bare sandbox-relative one. App-folder apps can't auto-discover this — the Dropbox API does not let the app see outside its own sandbox.

## 2.1.2

- **Fixed** verbose log output. The underlying uploader script's debug mode was printing a four-line banner (script version + `uname -a` + `/etc/issue`) to stdout on every invocation, which leaked into the add-on log even with the 2.1.1 stderr filter. Now filtered out under `debug: false`.

## 2.1.1

- **Added** `debug` config option (default `false`). When `false`, the underlying uploader script's bash xtrace is suppressed (was flooding the log with `+ curl ...` lines for every chunk of every upload). Set to `true` only when diagnosing an upload failure no other log lines explain.

## 2.1.0

- **Added** in-add-on OAuth flow via a new `auth_code` config field. Paste a one-time Dropbox authorization code into the Configuration tab and the add-on exchanges it for a long-lived refresh token, caching the result in `/data/refresh_token`. No external Python helper required.
- **Added** explicit error diagnostics on the startup auth check: `invalid_client` (app key/secret mismatch), `invalid_grant` (bad/revoked refresh token), and a "no authorization on file" path that prints the exact Dropbox authorize URL with `app_key` and `token_access_type=offline` pre-filled, plus the five steps to complete the consent flow.
- **Changed** Legacy `refresh_token` config field still works for backwards compatibility — on first start it's adopted into `/data/refresh_token`.
- The standalone `get_refresh_token.py` helper still ships as an alternate path for users who prefer to mint the refresh token on a laptop.

## 2.0.0

- **Breaking** Configuration schema rewritten for Dropbox API v2 and the modern OAuth refresh-token flow:
  - **Removed** `oauth_access_token`. Dropbox shut down long-lived access tokens, which is what broke the 1.x add-on.
  - **Added** `app_key`, `app_secret`, `refresh_token` (required for setup).
- **Changed** The add-on is now built locally by the Home Assistant Supervisor — no published Docker image. First install takes a couple of minutes; subsequent updates are fast.
- **Changed** `keep_last` uses the current Supervisor `/backups` API instead of the legacy `/snapshots` endpoint, fixing the `X-HASSIO-KEY` header and `http://hassio/` hostname both of which had been retired.
- **Added** `armv7` architecture support.
- The `dropbox_uploader.sh` script is now pinned at image-build time to a specific upstream commit. The 1.x add-on broke when Dropbox shut down API v1 in 2017 because its Docker image had baked in a stale copy of the script; pinning a known-good version (Dropbox API v2 + refresh token support) prevents a repeat.
