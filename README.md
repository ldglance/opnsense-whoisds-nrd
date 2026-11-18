# OPNsense WhoisDS NRD

A lightweight OPNsense integration that collects WhoisDS Newly Registered Domains (NRD) daily archives, maintains a configurable rolling feed, and exposes it to Unbound DNSBL through a loopback-only HTTP endpoint.

> **Project status:** Community-maintained source installer for OPNsense 26.7.x. This repository is not an official OPNsense plugin and does not currently produce a signed or installable OPNsense package. Review the compatibility and installation notes before deploying it on a firewall.

## What it does

- Adds a **Services → WhoisDS NRD** dashboard for feed settings, service control, feed statistics, update timestamps, and Unbound ingestion status.
- Downloads only missing or invalid daily archives. Unchanged local archives are recognized using saved file metadata and are not downloaded or reparsed on every run.
- Tries the current UTC feed date first, then falls back to the previous date when the newest archive is not yet available.
- Maintains configurable rolling retention from 1–15 days (default: 3 days).
- Supports comma-separated DNS suffix exclusions, including multi-label suffixes such as `co.uk`. Exclusions apply to the published aggregate; source archives remain unchanged.
- Publishes both each apex domain and its wildcard subdomain entry (`example.com` and `*.example.com`).
- Skips aggregate generation when the input archives and settings have not changed.
- Invalidates only this plugin's Unbound URL cache when a changed feed needs ingestion. It does not change the global Unbound blocklist cache TTL or other feed caches.
- Verifies the expected NRD cache line count and that OPNsense regenerated its DNSBL database after the refresh.
- Uses a compact state snapshot so dashboard status requests do not rescan the domain archives or aggregate feed.
- Requires no third-party Python packages.

## Compatibility and requirements

| Item | Requirement / status |
|---|---|
| OPNsense | Targeted at 26.7.x; live field validation reported on 26.7.9_3 |
| Operating system | FreeBSD 15.x (as shipped with the tested OPNsense release) |
| Python | Python 3.13; scripts invoke `/usr/local/bin/python3.13` |
| Privileges | Root for installation and backend operations |
| DNS resolver | Unbound with DNSBL enabled/configured |
| Network | Outbound HTTPS access to WhoisDS to retrieve daily archives |
| Python dependencies | Standard library only |

Compatibility with older OPNsense releases, future releases, or nonstandard Python layouts is not guaranteed. Test on a backup or VM snapshot before deploying to a production firewall.

## Feed behavior

The plugin downloads daily archives from [WhoisDS Newly Registered Domains](https://www.whoisds.com/newly-registered-domains). The free historical archive window is provider-controlled and may be shorter than the configured retention. The updater tries today's UTC date first and falls back one day if that archive cannot be used. It only backfills missing dates needed for the selected retention window.

Settings are stored in the OPNsense configuration model and rendered by configd to `/var/db/whoisds-nrd/settings.conf`. The Python backend does not edit `config.xml` directly.

The stable output path is:

```text
http://127.0.0.1:18765/nrd-15days.txt
```

The `15days` portion is retained in the URL for compatibility; it does not override the selected retention setting. The HTTP service binds only to `127.0.0.1`. **Do not expose port 18765 on a LAN or WAN interface.**

### TLD/suffix exclusions

Enter suffixes separated by commas, for example:

```text
ru,cn,xyz,shop,bond,top
```

Optional leading `.` or `*.` notation is accepted. Matching respects DNS label boundaries: `co.uk` matches `example.co.uk`, but `notco.uk.example` does not match. The downloaded daily archives are preserved without exclusions so the aggregate can be rebuilt when filter settings change.

## Installation

This is a direct source install, not a package install. Use a release/tag or a reviewed commit rather than an unreviewed development branch whenever possible.

1. Back up the OPNsense configuration and take a VM snapshot where available.
2. Obtain and extract this repository on the firewall or copy the extracted source tree to it.
3. From the repository root, run the preflight and review every planned change:

   ```sh
   sh ./install.sh --dry-run
   ```

4. If the preflight is clean, install:

   ```sh
   sh ./install.sh
   ```

5. Confirm the service and status endpoint:

   ```sh
   configctl whoisds_nrd status
   ```

6. Open **Services → WhoisDS NRD**, review retention/exclusion settings, and click **Update Now** to seed the feed.

The installer registers configd actions and a local HTTP service. It does **not** create a Cron job or edit the Unbound DNSBL source list.

### Existing-install upgrade

Use `upgrade.sh` only for an installation previously made with this repository's `install.sh`, with its installer manifest still present. Do not run a fresh install over an existing direct install.

1. Back up `/var/db/whoisds-nrd` and the OPNsense configuration.
2. Place the new repository source on the firewall.
3. From its root, run:

   ```sh
   sh ./upgrade.sh --dry-run
   sh ./upgrade.sh
   ```

4. Verify the status and run one update:

   ```sh
   configctl whoisds_nrd status
   configctl whoisds_nrd update
   ```

The upgrade script backs up files it replaces and preserves the local feed data. It does not create, edit, or remove the operator's Cron jobs or Unbound source configuration. If the installation manifest is missing, stop rather than bypassing the safety check; use the documented migration/repair path once one is provided for that installation method.

## Configure Unbound DNSBL

In **Services → Unbound DNS → Blocklists**, add a custom blocklist URL:

```text
http://127.0.0.1:18765/nrd-15days.txt
```

Recommended settings:

- Enable the entry.
- Add the URL under **URLs of Blocklists**.
- Leave **Source Net(s)** empty to apply it to all client networks, or select only the intended networks.
- Set a descriptive label such as `NRD`.
- The predefined **Type of DNSBL** selector can remain empty for this custom URL.
- Do not duplicate the feed by also placing it in the manual domain or wildcard fields.

Save the Unbound configuration and run the Unbound DNSBL update. Use the OPNsense Blocklist Tester with a domain known to exist in the current feed and a source address covered by the policy.

When the aggregate changes, the plugin removes only the cache file for its own URL from `/tmp/bl_cache/` and invokes `configctl unbound dnsbl`. It then checks that the complete expected feed was cached and that `/var/unbound/data/dnsbl.json` was regenerated. This is an ingestion check, not a substitute for testing a known domain through the Blocklist Tester.

## Schedule updates

Create a daily Cron job under **System → Settings → Cron** using the configd action:

```text
whoisds_nrd update
```

Choose a local time that suits the firewall. The updater uses UTC to determine feed dates. Avoid creating multiple overlapping schedules; a file lock prevents concurrent updater runs.

## Useful commands

```sh
# Read dashboard/backend status
configctl whoisds_nrd status

# Check/download missing archives, rebuild if necessary, and refresh Unbound if required
configctl whoisds_nrd update

# Rebuild from local archives/settings only (no WhoisDS download)
configctl whoisds_nrd rebuild

# Force this feed's cache to be invalidated and verify Unbound ingestion
configctl whoisds_nrd refresh

# Start, stop, or restart the local HTTP service
configctl whoisds_nrd service.start
configctl whoisds_nrd service.stop
configctl whoisds_nrd service.restart

# Destructive: delete local daily archives and empty the published feed
configctl whoisds_nrd clear
```

**Clear is destructive.** It removes the plugin-managed date-named daily archives and empties the published aggregate. It preserves settings and other blocklist caches. Use it only when you intentionally want to rebuild the local history from scratch.

## Data and paths

| Path | Purpose |
|---|---|
| `/var/db/whoisds-nrd/daily/` | Raw daily archives, named `YYYY-MM-DD.txt` |
| `/var/db/whoisds-nrd/nrd-15days.txt` | Published apex + wildcard feed |
| `/var/db/whoisds-nrd/settings.conf` | configd-rendered runtime settings |
| `/var/db/whoisds-nrd/run-state.json` | Cached metrics, validation signatures, timestamps, and ingestion state |
| `/usr/local/opnsense/scripts/whoisds_nrd/` | Python backend scripts |
| `/usr/local/opnsense/mvc/app/` | OPNsense MVC controllers, model, and view |
| `/usr/local/opnsense/service/conf/actions.d/actions_whoisds_nrd.conf` | configd action definitions |

## Development and tests

No Python package installation is needed. With Python 3.13:

```sh
python3.13 -m unittest discover -s tests -v
python3.13 -m compileall -q src/opnsense/scripts/whoisds_nrd tests
for script in install.sh upgrade.sh uninstall.sh; do sh -n "$script"; done
python3.13 scripts/validate_sources.py
```

The GitHub Actions workflow runs the unit tests and source syntax/integrity checks. Those checks run on a generic CI runner; they do not emulate OPNsense or replace appliance testing. See [docs/TESTING.md](docs/TESTING.md), [docs/PACKAGING.md](docs/PACKAGING.md), [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md), and [docs/GITHUB_PUBLISHING.md](docs/GITHUB_PUBLISHING.md).

## Security notes

- The feed HTTP service must remain bound to `127.0.0.1`.
- The installer and updater require root privileges.
- The updater validates downloaded payloads, rejects undersized/error-page responses, uses atomic file replacement, and prevents overlapping runs.
- Do not publish `config.xml`, firewall backups, runtime state files, downloaded domain archives, or diagnostic logs from a live installation in a public issue.
- Newly registered domain feeds can include legitimate domains. Review policy impact and consider a limited source-network rollout before applying it to every client.

Report vulnerabilities privately where the repository's GitHub security reporting feature is enabled; do not post exploitable details in public issues. See [SECURITY.md](SECURITY.md).

## License and attribution

This project is distributed under **GPL-3.0-or-later**; see [`LICENSE`](LICENSE). The WhoisDS feed-date URL construction and archive retrieval approach were adapted from [PeterDaveHello/nrd-list-downloader](https://github.com/PeterDaveHello/nrd-list-downloader), which is also GPL-3.0-or-later. Its copyright and attribution are recorded in [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).

## Disclaimer

This project is an independent community integration and is not affiliated with or endorsed by OPNsense or WhoisDS. It is provided without warranty. Operators are responsible for validating feed behavior, false positives, firewall impact, and compliance with applicable terms.
