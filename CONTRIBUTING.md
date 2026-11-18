# Contributing

Thanks for considering a contribution. This project modifies an OPNsense firewall and interacts with Unbound, so changes should favor safety, predictable rollback, and testability.

## Before opening an issue or pull request

- Search existing issues and pull requests.
- Describe the OPNsense version and Python version.
- Include the exact command, relevant sanitized log excerpt, and expected/actual behavior.
- Remove public IPs, private hostnames, usernames, serial numbers, API keys, tokens, configuration backups, and customer/domain data that should not be public.
- Do not attach `/conf/config.xml`, full firewall backups, runtime state files, or raw daily feed archives.

## Development checks

The Python backend uses only the standard library. Python 3.13 is the target runtime.

```sh
python3.13 -m unittest discover -s tests -v
python3.13 -m compileall -q src/opnsense/scripts/whoisds_nrd tests
for script in install.sh upgrade.sh uninstall.sh; do sh -n "$script"; done
python3.13 scripts/validate_sources.py
```

Also manually review changed OPNsense XML, PHP, Volt/JavaScript, service, and configd integration files. A successful local test run does not prove compatibility with a live OPNsense release.

## Change expectations

- Preserve the loopback-only HTTP bind (`127.0.0.1`).
- Never silently broaden filesystem deletion or cache invalidation beyond plugin-owned paths.
- Keep updates atomic and safe to retry.
- Do not delete or rewrite user feed data during an upgrade.
- Add unit tests for behavior changes, especially date fallback, retention pruning, cached validation, aggregate signatures, and Unbound refresh/verification.
- Update the README and relevant docs when behavior, requirements, configuration, or operator steps change.
- Keep commits focused and explain operational risk in the pull request.

## Pull requests

Include a summary, rationale, test output, OPNsense versions tested, and any migration/rollback considerations. Mark live-firewall validation separately from mocked/unit tests.
