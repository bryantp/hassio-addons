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

uploader() {
    /dropbox_uploader.sh -s -f "$UPLOADER_CONF" "$@"
}

print_last_response() {
    local last
    last=$(ls -t /tmp/du_resp_* 2>/dev/null | head -1 || true)
    if [[ -n "$last" && -s "$last" ]]; then
        echo "[Debug] Dropbox response body:"
        sed 's/^/[Debug]   /' "$last"
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

echo "[Info] Verifying Dropbox credentials..."
if ! uploader info > /tmp/info_out 2>&1; then
    echo "[Error] Dropbox authentication failed."
    sed 's/^/[Error]   /' /tmp/info_out
    print_last_response
    echo "[Error] Common causes:"
    echo "[Error]   * The Dropbox app's Permissions tab is missing files.content.write / files.content.read, or you forgot to click Submit at the bottom of that tab."
    echo "[Error]   * The refresh_token was minted before the permissions were granted — re-run get_refresh_token.py to mint a new one."
    echo "[Error]   * The app_key, app_secret, or refresh_token in the add-on Configuration tab is wrong."
    exit 1
fi
sed 's/^/[Info]   /' /tmp/info_out
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
