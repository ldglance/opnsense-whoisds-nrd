# Architecture

## Data flow

```text
WhoisDS daily archive (HTTPS)
          |
          v
updater.py -- validate + normalize
          |
          v
/var/db/whoisds-nrd/daily/YYYY-MM-DD.txt
          |
          v
retention + suffix exclusions + apex/wildcard generation
          |
          v
/var/db/whoisds-nrd/nrd-15days.txt
          |
          v
127.0.0.1:18765/nrd-15days.txt
          |
          v
OPNsense Unbound DNSBL download/cache/parser
```

The OPNsense MVC page manages settings and invokes backend operations through configd. The Python backend reads a small generated `settings.conf`; it does not directly edit the OPNsense XML configuration database.

## Update path

1. Acquire the update lock to prevent overlapping scheduled and manual runs.
2. Record the check time and read retention/exclusion settings.
3. Check the current UTC feed date, then the previous date as a publication fallback.
4. Reuse a valid local archive if its saved signature (size, nanosecond modification time, and inode) still matches. Otherwise download and validate it.
5. Fetch only missing dates needed to fill the configured window, subject to provider availability.
6. Prune date-named archives outside the established window.
7. Compare the archive/settings signature with the last aggregate signature. If unchanged and the output is still current, reuse cached metrics and skip a full aggregate rebuild.
8. If the output changed or its Unbound ingestion is pending, invalidate only the cache entry for this plugin URL and run `configctl unbound dnsbl`.
9. Check the cached line count and that the Unbound DNSBL JSON database was regenerated. Record `verified`, `failed`, or `pending` ingestion state.

The post-refresh check detects common stale-cache and parser-not-run cases. The OPNsense Blocklist Tester should still be used to test a known feed domain under the relevant source-network policy.

## Low-overhead status path

`status.py` reads `/var/db/whoisds-nrd/run-state.json`, reads the small settings file, stats the published output, and probes the loopback health endpoint. It does not parse daily archives or scan the aggregate to reconstruct dashboard counts.

## Important paths

- Data: `/var/db/whoisds-nrd/`
- Daily archives: `/var/db/whoisds-nrd/daily/`
- Published feed: `/var/db/whoisds-nrd/nrd-15days.txt`
- Runtime status and validation cache: `/var/db/whoisds-nrd/run-state.json`
- HTTP service: `/usr/local/opnsense/scripts/whoisds_nrd/updater.py --serve`
- Service rc.d script: `/usr/local/etc/rc.d/whoisds_nrd`
- Unbound URL cache directory: `/tmp/bl_cache/`
- Unbound DNSBL database: `/var/unbound/data/dnsbl.json`

## State and failure handling

- Feed writes and the runtime state JSON are written atomically.
- A failed or intentionally skipped Unbound refresh remains pending/failed; it is not marked as verified solely because `configctl` returned zero.
- A missing volatile `/tmp/bl_cache` entry causes a subsequent update to retry ingestion.
- If the newest archive is not available, the updater falls back one date and only prunes after establishing a usable anchor.
- Clear/reset is intentionally destructive to plugin-managed daily archives and the aggregate; it preserves settings and unrelated Unbound caches.
