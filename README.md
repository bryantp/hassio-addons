# Home Assistant Add-ons

[![License][license-shield]](LICENSE)

A small personal repository of Home Assistant add-ons.

## Installation

In Home Assistant, go to **Settings → Add-ons → Add-on Store → ⋮ → Repositories**
and add the URL of this repository. The add-ons below will then appear in the
store and the Supervisor will build them on your device on first install.

## Add-ons

### [Dropbox Sync](./dropbox-sync)

Upload your Home Assistant backups to Dropbox. Uses Dropbox API v2 with the
modern refresh-token OAuth flow. See [the add-on README](./dropbox-sync/README.md)
for setup.

## Credit

The original `dropbox-sync` add-on is by [@danielwelch][upstream]. This
repository is a personal fork that modernizes it for Dropbox API v2 and the
current Home Assistant Supervisor.

[upstream]: https://github.com/danielwelch/hassio-dropbox-sync
[license-shield]: https://img.shields.io/badge/license-Apache_2.0-blue.svg?style=flat
