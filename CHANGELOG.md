# Changelog

Notable changes to this project are recorded here. Dates refer to source changes, not necessarily to a published binary package.

## Unreleased

- Added configurable rolling retention (1–15 days, default 3) and TLD/suffix exclusions.
- Added apex and wildcard entries for each included domain.
- Added newest-date-first archive discovery with a one-day publication fallback.
- Added metadata-based validation caching to avoid repeatedly parsing unchanged daily archives.
- Added aggregate input signatures to skip unchanged feed rebuilds.
- Added lightweight dashboard status backed by a compact runtime state snapshot.
- Added targeted invalidation of the NRD URL cache and post-refresh ingestion checks.
- Added update, rebuild, refresh, clear, and local service actions through configd.
