#!/bin/bash
set -euo pipefail

CONFIG_PATH=/data/options.json
UPLOADER_CONF=/etc/uploader.conf
REFRESH_TOKEN_CACHE=/data/refresh_token
LAST_AUTH_CODE_FILE=/data/last_auth_code

APP_KEY=$(jq --raw-output '.app_key // empty' "$CONFIG_PATH")
APP_SECRET=$(jq --raw-output '.app_secret // empty' "$CONFIG_PATH")
AUTH_CODE=$(jq --raw-output '.auth_code // empty' "$CONFIG_PATH")
CONFIG_REFRESH_TOKEN=$(jq --raw-output '.refresh_token // empty' "$CONFIG_PATH")
OUTPUT_DIR=$(jq --raw-output '.output // empty' "$CONFIG_PATH")
DISPLAY_PATH=$(jq --raw-output '.display_path // empty' "$CONFIG_PATH")
KEEP_LAST=$(jq --raw-output '.keep_last // empty' "$CONFIG_PATH")
DROPBOX_KEEP_LAST=$(jq --raw-output '.dropbox_keep_last // empty' "$CONFIG_PATH")
FILETYPES=$(jq --raw-output '.filetypes // empty' "$CONFIG_PATH")
DEBUG=$(jq --raw-output '.debug // false' "$CONFIG_PATH")

if [[ -z "$APP_KEY" || -z "$APP_SECRET" ]]; then
    echo "[Error] app_key and app_secret are required."
    echo "[Error] Get them from your Dropbox app's Settings tab:"
    echo "[Error]   https://www.dropbox.com/developers/apps"
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="/"
fi

# Render the friendly Dropbox-visible directory (DISPLAY_PATH + OUTPUT_DIR)
# for log messages. Falls back to OUTPUT_DIR if no DISPLAY_PATH is set.
resolved_dir() {
    local d
    if [[ -n "$DISPLAY_PATH" ]]; then
        d="${DISPLAY_PATH%/}/${OUTPUT_DIR#/}"
    else
        d="$OUTPUT_DIR"
    fi
    echo "$d" | sed 's#/\+#/#g'
}

resolved_file() {
    local dir
    dir="$(resolved_dir)"
    dir="${dir%/}"
    echo "${dir}/$1"
}

print_authorize_url() {
    echo "[Info]   https://www.dropbox.com/oauth2/authorize?client_id=${APP_KEY}&response_type=code&token_access_type=offline"
}

print_authorization_instructions() {
    echo "[Error] No Dropbox authorization on file. To authorize this add-on:"
    echo "[Error]"
    echo "[Error]   1. Open this URL in a browser (you may need to log in to Dropbox):"
    print_authorize_url | sed 's/^\[Info\]/[Error]/'
    echo "[Error]"
    echo "[Error]   2. Click 'Continue' and then 'Allow'."
    echo "[Error]   3. Copy the authorization code Dropbox displays."
    echo "[Error]   4. Paste it into the 'auth_code' field on this add-on's Configuration tab."
    echo "[Error]   5. Save and restart the add-on."
    echo "[Error]"
    echo "[Error] The auth_code is single-use and expires within minutes. After"
    echo "[Error] exchange, the add-on stores the long-lived refresh_token in"
    echo "[Error] /data/refresh_token and ignores auth_code on future starts."
}

# Exchange an authorization code for a refresh_token + cache it to /data.
exchange_auth_code() {
    local code="$1"
    local resp_file=/tmp/exchange_resp
    local status

    echo "[Info] Exchanging auth_code for a refresh_token..."
    status=$(curl -s -o "$resp_file" -w "%{http_code}" \
        -d "code=${code}" \
        -d grant_type=authorization_code \
        -u "${APP_KEY}:${APP_SECRET}" \
        https://api.dropbox.com/oauth2/token || echo "000")

    if [[ "$status" != "200" ]]; then
        echo "[Error] auth_code exchange failed (HTTP ${status})."
        echo "[Error] Response body:"
        sed 's/^/[Error]   /' "$resp_file"
        local dropbox_error
        dropbox_error=$(jq -r '.error // empty' "$resp_file" 2>/dev/null || true)
        case "$dropbox_error" in
            invalid_grant)
                echo "[Error] => auth_code is invalid, already used, or expired."
                echo "[Error]    Auth codes are single-use and last only a few minutes."
                echo "[Error]    Visit the URL again to get a fresh code:"
                print_authorize_url | sed 's/^\[Info\]/[Error]/'
                ;;
            invalid_client)
                echo "[Error] => app_key and app_secret do not match a valid Dropbox app."
                ;;
        esac
        return 1
    fi

    local refresh
    refresh=$(jq -r '.refresh_token // empty' "$resp_file")
    if [[ -z "$refresh" ]]; then
        echo "[Error] Dropbox accepted the auth_code but did not return a refresh_token."
        echo "[Error] This means the authorize URL was missing token_access_type=offline."
        echo "[Error] Visit the URL below to get a fresh auth_code with the right scope:"
        print_authorize_url | sed 's/^\[Info\]/[Error]/'
        return 1
    fi

    umask 077
    printf '%s' "$refresh" > "$REFRESH_TOKEN_CACHE"
    echo "[Info] refresh_token cached in add-on persistent storage."
    echo "[Info] You may now clear the auth_code field on the Configuration tab"
    echo "[Info] (it is single-use; the cached refresh_token is used on future starts)."
    return 0
}

# Resolve a usable refresh_token, in order of precedence:
#   1. A NEW auth_code in config that we haven't seen before -> exchange it.
#   2. A cached refresh_token in /data/refresh_token.
#   3. A legacy refresh_token in config -> cache and use.
#   4. Nothing -> print authorize URL and exit.
prev_auth_code=""
if [[ -s "$LAST_AUTH_CODE_FILE" ]]; then
    prev_auth_code=$(cat "$LAST_AUTH_CODE_FILE")
fi

if [[ -n "$AUTH_CODE" && "$AUTH_CODE" != "$prev_auth_code" ]]; then
    if ! exchange_auth_code "$AUTH_CODE"; then
        exit 1
    fi
    umask 077
    printf '%s' "$AUTH_CODE" > "$LAST_AUTH_CODE_FILE"
fi

if [[ ! -s "$REFRESH_TOKEN_CACHE" ]]; then
    if [[ -n "$CONFIG_REFRESH_TOKEN" ]]; then
        umask 077
        printf '%s' "$CONFIG_REFRESH_TOKEN" > "$REFRESH_TOKEN_CACHE"
    else
        print_authorization_instructions
        exit 1
    fi
fi

REFRESH_TOKEN=$(cat "$REFRESH_TOKEN_CACHE")

umask 077
cat > "$UPLOADER_CONF" <<EOF
CONFIGFILE_VERSION=2.0
OAUTH_APP_KEY=${APP_KEY}
OAUTH_APP_SECRET=${APP_SECRET}
OAUTH_REFRESH_TOKEN=${REFRESH_TOKEN}
OAUTH_ACCESS_TOKEN=
OAUTH_ACCESS_TOKEN_EXPIRE=0
EOF

# -d puts dropbox_uploader.sh in debug mode, which (a) preserves the
# response file at the known path /tmp/du_resp_debug, (b) enables
# bash xtrace on stderr, and (c) prints a banner of script version
# + uname -a + /etc/issue to stdout on EVERY invocation. We want (a)
# — without it the script deletes the response file before we can
# dump it on failure — but (b) and (c) are noise. With debug=false:
# swallow xtrace (stderr) and filter the four known banner lines off
# stdout. With debug=true: let everything through.
# -s skips files that already exist in Dropbox.
RESPONSE_FILE=/tmp/du_resp_debug
DEBUG_NOISE_REGEX='^([0-9]+\.[0-9]+|Linux .* SMP |Welcome to Alpine|Kernel )'

if [[ "$DEBUG" == "true" ]]; then
    uploader() {
        /dropbox_uploader.sh -d -s -f "$UPLOADER_CONF" "$@"
    }
else
    uploader() {
        # pipefail propagates the uploader's exit status; the `|| true`
        # on the grep side ensures the pipeline never falsely fails just
        # because every output line happened to match the noise filter.
        /dropbox_uploader.sh -d -s -f "$UPLOADER_CONF" "$@" 2>/dev/null \
            | { grep -vE "$DEBUG_NOISE_REGEX" || true; }
    }
fi

print_last_response() {
    if [[ -s "$RESPONSE_FILE" ]]; then
        echo "[Debug] Dropbox response body:"
        sed 's/^/[Debug]   /' "$RESPONSE_FILE"
    fi
}

# Prune Dropbox to keep only the N newest .tar files PER NAME PREFIX in
# OUTPUT_DIR. Home Assistant produces backup filenames of the form
#   <Prefix>_<version>_<YYYY-MM-DD>_<HH>.<MM>_<hash>.tar
# (e.g. AdGuard_Home_6.1.2_2026-06-12_14.17_56119900.tar). The regex below
# strips the trailing version+date+time+hash so backups of each
# addon/category share a prefix bucket. Per-bucket retention prevents the
# daily Automatic_backup from evicting rarely-regenerated addon backups.
# Files that do not match the HA pattern fall into a single "_unmatched"
# bucket.
# Restricted to *.tar so non-backup uploads (from FILETYPES) are not touched.
prune_dropbox() {
    local keep=$1
    local fresh_resp=/tmp/prune_token_resp
    local fresh_status fresh_token api_path

    fresh_status=$(curl -s -o "$fresh_resp" -w "%{http_code}" \
        -d grant_type=refresh_token \
        -d "refresh_token=${REFRESH_TOKEN}" \
        -u "${APP_KEY}:${APP_SECRET}" \
        https://api.dropbox.com/oauth2/token || echo "000")
    if [[ "$fresh_status" != "200" ]]; then
        echo "[Warn] Dropbox prune: could not refresh access token (HTTP ${fresh_status})."
        sed 's/^/[Warn]   /' "$fresh_resp"
        return 1
    fi
    fresh_token=$(jq -r '.access_token' "$fresh_resp")

    # Dropbox list_folder wants "" for the namespace root, "/foo" for a subdir.
    api_path="${OUTPUT_DIR%/}"
    [[ "$api_path" == "" || "$api_path" == "/" ]] && api_path=""

    local entries_dir resp status has_more cursor page
    entries_dir=$(mktemp -d)
    page=0
    resp="${entries_dir}/page_0"
    status=$(curl -s -o "$resp" -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${fresh_token}" \
        -H "Content-Type: application/json" \
        --data "{\"path\":\"${api_path}\"}" \
        https://api.dropboxapi.com/2/files/list_folder || echo "000")
    if [[ "$status" != "200" ]]; then
        echo "[Warn] Dropbox prune: list_folder failed (HTTP ${status})."
        sed 's/^/[Warn]   /' "$resp"
        rm -rf "$entries_dir"
        return 1
    fi
    has_more=$(jq -r '.has_more' "$resp")
    cursor=$(jq -r '.cursor' "$resp")
    while [[ "$has_more" == "true" ]]; do
        page=$((page+1))
        resp="${entries_dir}/page_${page}"
        status=$(curl -s -o "$resp" -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${fresh_token}" \
            -H "Content-Type: application/json" \
            --data "{\"cursor\":\"${cursor}\"}" \
            https://api.dropboxapi.com/2/files/list_folder/continue || echo "000")
        if [[ "$status" != "200" ]]; then
            echo "[Warn] Dropbox prune: list_folder/continue failed (HTTP ${status})."
            sed 's/^/[Warn]   /' "$resp"
            rm -rf "$entries_dir"
            return 1
        fi
        has_more=$(jq -r '.has_more' "$resp")
        cursor=$(jq -r '.cursor' "$resp")
    done

    # Single jq pass: tag each .tar entry with the HA-pattern prefix,
    # group by prefix, then per group compute total/keep/delete_paths.
    local summary
    summary=$(jq -s --argjson keep "$keep" '
        [ .[] | .entries[] ]
        | map(select(.[".tag"] == "file" and (.name | endswith(".tar"))))
        | map(. + {
            prefix: (
                .name
                | ((match("^(.+?)_[0-9]+(\\.[0-9]+)+_[0-9]{4}-[0-9]{2}-[0-9]{2}_") // null)
                   | (if . == null then "_unmatched" else .captures[0].string end))
            )
          })
        | group_by(.prefix)
        | map({
            prefix: (.[0].prefix),
            total: length,
            keep: ([length, $keep] | min),
            delete_paths: (
                (length - $keep) as $del
                | if $del <= 0 then []
                  else sort_by(.server_modified) | .[0:$del] | map(.path_lower)
                  end
            )
          })
    ' "${entries_dir}"/page_*)

    local total_files total_to_delete num_groups
    total_files=$(echo "$summary" | jq '[.[].total] | add // 0')
    total_to_delete=$(echo "$summary" | jq '[.[].delete_paths | length] | add // 0')
    num_groups=$(echo "$summary" | jq 'length')

    if [[ "$total_files" == "0" ]]; then
        echo "[Info] Dropbox prune: no .tar files in ${OUTPUT_DIR}, nothing to delete."
        rm -rf "$entries_dir"
        return 0
    fi

    echo "[Info] Dropbox prune: per-prefix retention, keep newest ${keep} of each."
    echo "[Info]   ${total_files} .tar file(s) across ${num_groups} prefix bucket(s); deleting ${total_to_delete} oldest."
    echo "$summary" \
        | jq -r '.[] | "  - \(.prefix): \(.total) file(s), keeping \(.keep), deleting \(.delete_paths | length)"' \
        | while IFS= read -r line; do
            echo "[Info]   $line"
        done

    if [[ "$total_to_delete" == "0" ]]; then
        rm -rf "$entries_dir"
        return 0
    fi

    local stale_paths
    stale_paths=$(echo "$summary" | jq -r '.[].delete_paths[]')

    while IFS= read -r dp; do
        [[ -z "$dp" ]] && continue
        local del_resp=/tmp/prune_del_resp
        local del_status
        del_status=$(curl -s -o "$del_resp" -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${fresh_token}" \
            -H "Content-Type: application/json" \
            --data "$(jq -n --arg p "$dp" '{path:$p}')" \
            https://api.dropboxapi.com/2/files/delete_v2 || echo "000")
        if [[ "$del_status" == "200" ]]; then
            echo "[Info]     Deleted from Dropbox: ${dp}"
        else
            echo "[Warn]     Failed to delete from Dropbox: ${dp} (HTTP ${del_status})"
            sed 's/^/[Warn]       /' "$del_resp"
        fi
    done <<< "$stale_paths"

    rm -rf "$entries_dir"
}

echo "[Info] ----- Dropbox Sync configuration -----"
echo "[Info] Backups source dir:    /backup"
if [[ -n "$FILETYPES" ]]; then
    echo "[Info] Share source dir:      /share (extensions: ${FILETYPES})"
fi
echo "[Info] Dropbox destination:   $(resolved_dir)"
if [[ -z "$DISPLAY_PATH" ]]; then
    echo "[Info]   (this path is relative to the Dropbox app's scope. For an"
    echo "[Info]    App-folder app the real Dropbox-visible prefix is"
    echo "[Info]    /Apps/<your app folder name>. Set 'display_path' in the"
    echo "[Info]    Configuration tab to that prefix to see the full path here.)"
fi
if [[ -n "$KEEP_LAST" ]]; then
    echo "[Info] Keep last:             ${KEEP_LAST} backup(s) on the Supervisor"
fi
if [[ -n "$DROPBOX_KEEP_LAST" ]]; then
    echo "[Info] Dropbox keep last:     ${DROPBOX_KEEP_LAST} .tar file(s) in Dropbox"
fi
echo "[Info] ---------------------------------------"

# dropbox_uploader.sh silently swallows refresh-token errors, so verify
# the refresh exchange ourselves first to surface Dropbox's real error.
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
            ;;
        invalid_grant)
            echo "[Error] => 'invalid_grant' means the cached refresh_token is no longer valid"
            echo "[Error]    (revoked, app credentials rotated, or never offline-scoped)."
            echo "[Error]    To re-authorize: paste a fresh auth_code into the Configuration tab."
            echo "[Error]    Get one here:"
            print_authorize_url | sed 's/^\[Info\]/[Error]/'
            ;;
        *)
            echo "[Error] Re-authorize by pasting a fresh auth_code into the Configuration tab."
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
        echo "[Info] Uploading all .tar files in /backup to $(resolved_dir) (skipping those already in Dropbox)"
        shopt -s nullglob
        for f in /backup/*.tar; do
            if [[ -n "$DISPLAY_PATH" ]]; then
                echo "[Info] -> $(resolved_file "${f##*/}")"
            fi
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

        if [[ -n "$DROPBOX_KEEP_LAST" ]]; then
            echo "[Info] dropbox_keep_last option is set, pruning Dropbox..."
            prune_dropbox "$DROPBOX_KEEP_LAST" || echo "[Warn] dropbox_keep_last cleanup failed"
        fi

        if [[ -n "$FILETYPES" ]]; then
            echo "[Info] filetypes option is set, scanning /share for extensions: ${FILETYPES}"
            find /share -regextype posix-extended -regex "^.*\.(${FILETYPES})\$" -print0 \
                | while IFS= read -r -d '' f; do
                    if [[ -n "$DISPLAY_PATH" ]]; then
                        echo "[Info] -> $(resolved_file "${f##*/}")"
                    fi
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
