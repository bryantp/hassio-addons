#!/usr/bin/env python3
"""One-time helper: mint a Dropbox refresh token from an app key/secret.

Run this once on any machine with a browser available. It prints the
refresh_token you should paste into the add-on configuration.

Requires only the Python standard library.
"""
import getpass
import json
import sys
import urllib.parse
import urllib.request
import webbrowser


def main() -> int:
    print("Dropbox refresh token helper")
    print("---------------------------")
    print("Create an app at https://www.dropbox.com/developers/apps if you")
    print("haven't already. Choose 'Scoped access' and 'App folder' (or")
    print("'Full Dropbox' if you want the add-on to write anywhere).")
    print("Grant at least the files.content.write and files.content.read")
    print("scopes. Then copy the App key and App secret below.\n")

    app_key = input("App key: ").strip()
    app_secret = getpass.getpass("App secret (hidden): ").strip()
    if not app_key or not app_secret:
        print("App key and app secret are required.", file=sys.stderr)
        return 1

    authorize_url = (
        "https://www.dropbox.com/oauth2/authorize?"
        + urllib.parse.urlencode(
            {
                "client_id": app_key,
                "response_type": "code",
                "token_access_type": "offline",
            }
        )
    )
    print("\nOpening Dropbox authorization page in your browser...")
    print("If it does not open, visit this URL manually:")
    print(authorize_url, "\n")
    try:
        webbrowser.open(authorize_url)
    except webbrowser.Error:
        pass

    auth_code = input("Paste the authorization code from Dropbox: ").strip()
    if not auth_code:
        print("Authorization code is required.", file=sys.stderr)
        return 1

    body = urllib.parse.urlencode(
        {
            "code": auth_code,
            "grant_type": "authorization_code",
            "client_id": app_key,
            "client_secret": app_secret,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        "https://api.dropbox.com/oauth2/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as e:
        print(f"Dropbox rejected the code: {e.code} {e.read().decode()}", file=sys.stderr)
        return 1

    refresh_token = payload.get("refresh_token")
    if not refresh_token:
        print("Dropbox did not return a refresh_token. Response was:", file=sys.stderr)
        print(json.dumps(payload, indent=2), file=sys.stderr)
        return 1

    print("\nSuccess. Paste the following into your add-on configuration:\n")
    print(f"  app_key:       {app_key}")
    print(f"  app_secret:    {app_secret}")
    print(f"  refresh_token: {refresh_token}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
