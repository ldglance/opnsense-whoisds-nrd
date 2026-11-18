# Third-party notices

## WhoisDS NRD download/archive handling

The feed-date URL construction and archive retrieval approach in this project were adapted from:

- **Project:** [PeterDaveHello/nrd-list-downloader](https://github.com/PeterDaveHello/nrd-list-downloader)
- **Copyright:** Copyright (C) 2022 Peter Dave Hello
- **License:** GNU General Public License, version 3 or (at your option) any later version (GPL-3.0-or-later)

The upstream script contains its own copyright and GPL notice. This project is an OPNsense/Python integration and does not include the upstream shell script wholesale. The relevant adaptation is distributed under GPL-3.0-or-later; see the repository `LICENSE` file.

The upstream project itself credits [WhoisDS](https://www.whoisds.com/newly-registered-domains) as the NRD data source. This project is independent and is not affiliated with or endorsed by WhoisDS.

## Runtime dependencies

The plugin's Python backend uses the Python standard library. No third-party Python packages are vendored in this repository.
