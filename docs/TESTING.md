# Testing and validation

## Automated tests

The project uses Python's standard library only. From the repository root, with Python 3.13:

```sh
python3.13 -m unittest discover -s tests -v
python3.13 -m compileall -q src/opnsense/scripts/whoisds_nrd tests
for script in install.sh upgrade.sh uninstall.sh; do sh -n "$script"; done
python3.13 scripts/validate_sources.py
```

The unit tests use temporary directories and mocks for filesystem, download, configd, and Unbound behavior. They do not contact WhoisDS or modify a real firewall.

The GitHub Actions workflow runs unit tests, Python compilation, shell syntax validation, XML parsing, PHP lint, and JavaScript syntax checks.

## Appliance integration checklist

Run this on a disposable OPNsense VM or a backed-up test firewall. A CI pass is not an appliance integration test.

1. Confirm the target OPNsense version and `/usr/local/bin/python3.13` availability.
2. Run `sh ./install.sh --dry-run`; inspect all planned paths before installing.
3. Install and verify `configctl whoisds_nrd status`.
4. Confirm the HTTP listener is bound only to `127.0.0.1:18765`.
5. Check that `/health` returns `whoisds-nrd-ok` and the feed endpoint returns plain domain entries.
6. Add the feed URL to Unbound DNSBL and confirm the generated Unbound blocklist configuration contains it.
7. Run an update and inspect updater logs, daily archive dates, feed counts, and Unbound ingestion state.
8. Check the Unbound resolver log for the NRD URL's downloaded/cached line count and parser summary.
9. Use the OPNsense Blocklist Tester with a known domain in the feed and a source IP that is in scope for the policy. Confirm a non-listed control domain passes.
10. Repeat an unchanged update and confirm no archive download, aggregate rebuild, or unnecessary Unbound refresh occurs.
11. Modify retention/exclusions and confirm the aggregate rebuilds from local archives without re-downloading them.
12. Test service restart, firewall reboot persistence, failed download behavior, failed Unbound refresh retry, and uninstall dry-run/rollback in the test VM.

## Reported field-validation baseline

One field-validation environment was reported as OPNsense 26.7.9_3, FreeBSD 15.1-RELEASE-p6, and Python 3.13.18. This is a point-in-time compatibility data point, not a guarantee for every 26.7.x patch or future release.
