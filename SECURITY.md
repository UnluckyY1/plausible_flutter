# Security Policy

## Supported Versions

Only the latest minor release receives security fixes. Pin to a recent version and watch the repo for updates.

| Version | Supported |
| ------- | --------- |
| 0.4.x   | ✅        |
| < 0.4   | ❌        |

## Reporting a Vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's private vulnerability reporting:
[github.com/UnluckyY1/plausible_flutter/security/advisories/new](https://github.com/UnluckyY1/plausible_flutter/security/advisories/new)

That keeps the report private until a fix is published and gives us a tracked workflow for the advisory.

You can expect:

- An acknowledgement within 5 business days.
- A fix or mitigation timeline within 14 days of confirmation.
- Public credit in the advisory if you'd like it.

## What We Already Do

- **OSV-Scanner** runs on every pull request and on a weekly schedule against `pubspec.lock`. New CVEs in any dependency break the build.
- **Dependabot** opens weekly PRs for `pub` and `github-actions` updates.
- GitHub Actions are pinned by commit SHA, not by floating tag.
- The package validates `apiHost` at `init()` and warns when the configured host is plain HTTP.
- An optional 32-byte `encryptionKey` enables AES-256 encryption of the on-disk Hive queue.

## Cross-Checking the Scan

OSV-Scanner uses Google's OSV database, which mirrors GitHub Advisories, pub.dev advisories, and others. If you want belt-and-braces, run a second scanner once in a while — Trivy and Snyk both support Dart and pull from different aggregators:

```bash
# Trivy
trivy fs --scanners vuln .

# Snyk (requires an account)
snyk test --file=pubspec.yaml
```
