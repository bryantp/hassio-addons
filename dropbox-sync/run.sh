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

echo "[Info] Files will be uploaded to: ${OUTPUT_DIR}"

# Write the v2.0 config consumed by dropbox_uploader.sh.
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

echo "[Info] Listening for messages via stdin service call..."

while read -r msg; do
    echo "$msg"
    cmd="$(echo "$msg" | jq --raw-output '.command')"
    echo "[Info] Received message with command ${cmd}"

    if [[ "$cmd" = "upload" ]]; then
        echo "[Info] Uploading all .tar files in /backup (skipping those already in Dropbox)"
        shopt -s nullglob
        for f in /backup/*.tar; do
            uploader upload "$f" "$OUTPUT_DIR" || echo "[Warn] Upload failed for $f"
        done
        shopt -u nullglob

        if [[ -n "$KEEP_LAST" ]]; then
            echo "[Info] keep_last option is set, cleaning up old backups..."
            python3 /keep_last.py "$KEEP_LAST" || echo "[Warn] keep_last cleanup failed"
        fi

        if [[ -n "$FILETYPES" ]]; then
            echo "[Info] filetypes option is set, scanning /share for extensions: ${FILETYPES}"
            find /share -regextype posix-extended -regex "^.*\.(${FILETYPES})\$" -print0 \
                | while IFS= read -r -d '' f; do
                    uploader upload "$f" "$OUTPUT_DIR" || echo "[Warn] Upload failed for $f"
                done
        fi
    else
        echo "[Error] Command not found: ${cmd}"
    fi
done
