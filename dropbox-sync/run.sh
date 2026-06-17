#!/bin/bash
set -euo pipefail

CONFIG_PATH=/data/options.json
UPLOADER_CONF=/etc/uploader.conf

APP_KEY=$(jq --raw-output '.app_key // empty' "$CONFIG_PATH")
APP_SECRET=$(jq --raw-output '.app_secret // empty' "$CONFIG_PATH")
REFRESH_TOKEN=$(jq --raw-output '.refresh_token // empty' "$CONFIG_PATH")
OUTPUT_DIR=$(jq --raw-output '.output // empty' "$CONFIG_PATH")
KEEP_LAST=$(jq --raw-output '.keep_last // empty' "$CONFIG_PATH")
FILETYPES=$(jq --raw-output '.filetypes // empty' "$CONFIG_PATH")

if [[ -z "$APP_KEY" || -z "$APP_SECRET" || -z "$REFRESH_TOKEN" ]]; then
    echo "[Error] app_key, app_secret, and refresh_token are all required."
    echo "[Error] See the add-on README for how to generate them."
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="/"
fi

umask 077
cat > "$UPLOADER_CONF" <<EOF
CONFIGFILE_VERSION=2.0
OAUTH_APP_KEY=${APP_KEY}
OAUTH_APP_SECRET=${APP_SECRET}
OAUTH_REFRESH_TOKEN=${REFRESH_TOKEN}
OAUTH_ACCESS_TOKEN=
OAUTH_ACCESS_TOKEN_EXPIRE=0
EOF

# -d puts dropbox_uploader.sh in debug mode, which preserves the response
# file at the known path /tmp/du_resp_debug so we can surface the actual
# Dropbox error body when something fails. -s skips files that already
# exist in Dropbox.
RESPONSE_FILE=/tmp/du_resp_debug

uploader() {
    /dropbox_uploader.sh -d -s -f "$UPLOADER_CONF" "$@"
}

print_last_response() {
    if [[ -s "$RESPONSE_FILE" ]]; then
        echo "[Debug] Dropbox response body:"
        sed 's/^/[Debug]   /' "$RESPONSE_FILE"
    fi
}

echo "[Info] ----- Dropbox Sync configuration -----"
echo "[Info] Backups source dir:    /backup"
if [[ -n "$FILETYPES" ]]; then
    echo "[Info] Share source dir:      /share (extensions: ${FILETYPES})"
fi
echo "[Info] Dropbox destination:   ${OUTPUT_DIR}"
if [[ -n "$KEEP_LAST" ]]; then
    echo "[Info] Keep last:             ${KEEP_LAST} backup(s) on the Supervisor"
fi
echo "[Info] ---------------------------------------"

# dropbox_uploader.sh silently swallows refresh-token errors (it never
# checks the HTTP status of the /oauth2/token call and just runs
# requests with an empty Bearer token if the refresh failed), so do the
# refresh exchange ourselves first and surface Dropbox's actual error.
echo "[Info] Verifying Dropbox credentials..."
AUTH_RESPONSE=/tmp/oauth_resp
HTTP_STATUS=$(curl -s -o "$AUTH_RESPONSE" -w "%{http_code}" \
    -d grant_type=refresh_token \
    -d "refresh_token=${REFRESH_TOKEN}" \
    -u "${APP_KEY}:${APP_SECRET}" \
    https://api.dropbox.com/oauth2/token || echo "000")

if [[ "$HTTP_STATUS" != "200" ]] || ! jq -e '.access_token' "$AUTH_RESPONSE" > /dev/null 2>&1; then
    echo "[Error] Dropbox refresh-token exchange failed (HTTP ${HTTP_STATUS})."
    echo "[Error] Response body:"
    sed 's/^/[Error]   /' "$AUTH_RESPONSE"
    DROPBOX_ERROR=$(jq -r '.error // empty' "$AUTH_RESPONSE" 2>/dev/null || true)
    case "$DROPBOX_ERROR" in
        invalid_client)
            echo "[Error] => 'invalid_client' means app_key and app_secret do not match a valid Dropbox app."
            echo "[Error]    Check Settings tab in your Dropbox app for the correct App key and (click Show) App secret."
            ;;
        invalid_grant)
            echo "[Error] => 'invalid_grant' means the refresh_token is bad — wrong app, revoked, or never offline-scoped."
            echo "[Error]    Re-run get_refresh_token.py (which uses token_access_type=offline) to mint a new one."
            ;;
        *)
            echo "[Error] Common causes:"
            echo "[Error]   * The app_key, app_secret, or refresh_token in the add-on Configuration tab is wrong."
            echo "[Error]   * The refresh_token was minted before the Dropbox app's Permissions were granted/submitted."
            echo "[Error]   * The Dropbox app's Permissions tab is missing files.content.write / files.content.read, and Submit was never clicked at the bottom of that tab."
            ;;
    esac
    exit 1
fi

ACCOUNT_INFO=/tmp/account_info
ACCESS_TOKEN=$(jq -r '.access_token' "$AUTH_RESPONSE")
ACCOUNT_STATUS=$(curl -s -o "$ACCOUNT_INFO" -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    https://api.dropboxapi.com/2/users/get_current_account || echo "000")

if [[ "$ACCOUNT_STATUS" != "200" ]]; then
    echo "[Error] Auth succeeded but get_current_account returned HTTP ${ACCOUNT_STATUS}."
    echo "[Error] Response body:"
    sed 's/^/[Error]   /' "$ACCOUNT_INFO"
    exit 1
fi

echo "[Info]   Account: $(jq -r '.name.display_name' "$ACCOUNT_INFO") <$(jq -r '.email' "$ACCOUNT_INFO")>"
echo "[Info] Authentication OK."

echo "[Info] Listening for messages via stdin service call..."

while read -r msg; do
    echo "$msg"
    cmd="$(echo "$msg" | jq --raw-output '.command')"
    echo "[Info] Received message with command ${cmd}"

    if [[ "$cmd" = "upload" ]]; then
        echo "[Info] Uploading all .tar files in /backup to ${OUTPUT_DIR} (skipping those already in Dropbox)"
        shopt -s nullglob
        for f in /backup/*.tar; do
            if ! uploader upload "$f" "$OUTPUT_DIR"; then
                echo "[Warn] Upload failed for $f"
                print_last_response
            fi
        done
        shopt -u nullglob

        if [[ -n "$KEEP_LAST" ]]; then
            echo "[Info] keep_last option is set, pruning Supervisor backups..."
            python3 /keep_last.py "$KEEP_LAST" || echo "[Warn] keep_last cleanup failed"
        fi

        if [[ -n "$FILETYPES" ]]; then
            echo "[Info] filetypes option is set, scanning /share for extensions: ${FILETYPES}"
            find /share -regextype posix-extended -regex "^.*\.(${FILETYPES})\$" -print0 \
                | while IFS= read -r -d '' f; do
                    if ! uploader upload "$f" "$OUTPUT_DIR"; then
                        echo "[Warn] Upload failed for $f"
                        print_last_response
                    fi
                done
        fi
    else
        echo "[Error] Command not found: ${cmd}"
    fi
done
