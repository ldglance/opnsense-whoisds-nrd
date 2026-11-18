# Security policy

## Supported version

Security fixes are intended for the current development line. Older snapshots may not receive fixes.

## Reporting a vulnerability

Please do not disclose exploitable details in a public issue. If GitHub private vulnerability reporting is enabled for this repository, use it. Otherwise contact the repository owner through the GitHub profile and request a private reporting channel before sending technical details.

Do not include firewall backups, `config.xml`, credentials, API tokens, private keys, or unredacted logs in a report.

## Security design notes

- The local feed server is intended to bind exclusively to `127.0.0.1` on TCP port `18765`.
- The backend is invoked by OPNsense configd and runs with firewall-level privileges.
- The installer modifies files under `/usr/local`, `/etc/rc.conf.d`, and `/var/db`; it provides dry-run and rollback mechanisms.
- Cache invalidation is scoped to the MD5-derived cache filename for the plugin's exact local feed URL.
- The plugin does not provide authentication for a non-loopback HTTP listener. Do not expose the feed service to other networks.
