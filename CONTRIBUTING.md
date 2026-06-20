# Contributing to Capecho

Thanks for your interest in Capecho. Contributions — bug reports, fixes, features, docs, and new
target-language proposals — are welcome.

## How changes land

This repository is the **public, source-available mirror** of Capecho's primary (private) development
repository — all development happens upstream and a clean, scrubbed snapshot is published here each
release. **Issues and pull requests are welcome here.** When we accept a PR, we apply your commits
upstream with your `Signed-off-by` / `Co-authored-by` lines preserved, and they ship in the next
published release. At that point we close the PR here noting the version it landed in — so an accepted
contribution shows as **closed (landed in vX.Y.Z)**, not "merged," but your authorship is preserved in
the release. (This is why the public history is one clean commit per version.)

## License & sign-off (DCO)

Capecho is source-available under the Functional Source License v1.1 (FSL-1.1-Apache-2.0). By
contributing, you agree that your contributions are licensed under the same terms (inbound = outbound).

We use the [Developer Certificate of Origin](https://developercertificate.org/) (DCO) instead of a
CLA. It is a lightweight statement that you wrote, or have the right to submit, the code you're
contributing. Sign off every commit — `git commit -s` adds the line for you:

```
Signed-off-by: Your Name <you@example.com>
```

The name/email must be real and match the commit author. PRs whose commits aren't signed off will be
asked to amend.

## Before you start

- **Read the invariants first.** The load-bearing product/design decisions are summarized in
  [`CLAUDE.md`](CLAUDE.md) and the design system in [`DESIGN.md`](DESIGN.md). Please don't re-litigate
  them in a PR (e.g. multi-target not English-only, the captured unit is immutable, FSRS is
  server-authoritative, capture never uploads a screen image). For anything that changes behavior or
  proposes a new target language, open an issue to discuss first.
- **One concern per PR.** Smaller, focused PRs land faster.

## Building & testing

Each package has its own README with build/test commands. In short:

| Area | Toolchain | Test |
|---|---|---|
| `clients/macos`, `clients/mobile`, `shared/*` (Dart) | Flutter / Dart | `flutter test` / `dart test`; format with `dart format -l 100` |
| `backend` | Bun | `bun test` · `bun run typecheck` · `bun run test:integration` |
| `web` | Node / Next.js | the package's scripts |

Make sure the relevant suite is green and the tree is format-clean before opening a PR — CI runs the
whole-tree `dart format -l 100 --set-exit-if-changed` check, `dart analyze`, and the backend suites,
and will fail the PR otherwise.

## Pull request flow

1. Fork and branch from `main`.
2. Make your change with signed-off commits (`git commit -s`).
3. Run the relevant tests/format locally.
4. Open a PR describing **what** and **why**; link any issue.
5. CI gates the PR before review.

## Security

Please **do not** open public issues for security vulnerabilities. Report them privately per
[`SECURITY.md`](SECURITY.md).
