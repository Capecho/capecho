# Security policy

We take the security of Capecho and its users' data seriously. Thank you for
helping keep it safe.

## Reporting a vulnerability

**Please do not report security issues through public GitHub issues, pull
requests, or discussions.**

Instead, report privately via one of:

- GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
  ("Report a vulnerability" under the repository's **Security** tab), or
- Email **security@capecho.com**.

Please include enough detail to reproduce: the affected component
(backend / macOS / iOS), a description of the issue and its impact, and
step-by-step reproduction or a proof of concept. If you have a suggested fix,
even better.

## What to expect

- We aim to acknowledge your report within **3 business days**.
- We'll work with you to understand and validate the issue and keep you updated
  on remediation.
- We support coordinated disclosure: please give us a reasonable window to ship
  a fix before any public write-up, and we're happy to credit you (or stay
  anonymous, your choice).

## Scope

In scope: the Capecho backend (Cloudflare Workers + D1), the macOS and iOS
clients, and the shared packages in this repository.

Out of scope: vulnerabilities in third-party dependencies (report those
upstream), findings that require a compromised device or a privileged
local/network position, and self-hosted forks not operated by Capecho.

## Supported versions

Security fixes target the latest released version (see [`VERSION`](VERSION) and
the top of [`CHANGELOG.md`](CHANGELOG.md)). We don't backport to older versions.
