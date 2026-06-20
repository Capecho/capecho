# @capecho/lang

BCP-47 **canonicalization + validation**, the **target-generation profile registry**
(the explanation-generation allowlist), language **prompt names**, and the closed
**POS label set**.

## Canonicalization (server-authoritative)

`canonicalizeBcp47(tag)` → canonical tag, or `null` if malformed / structurally
invalid / pure private-use. Uses the platform `Intl.getCanonicalLocales` (Layer 1):
`zh-hans → zh-Hans`, `EN → en`, `en-us → en-US`, `zh-Hant` stays distinct.

The server honors the user's **explicit** target-language selection but never trusts
an arbitrary client string — it canonicalizes + validates on sync and re-keys if the
client used a non-canonical tag (same provisional-client / authoritative-server
pattern as the deterministic dedup key in `backend/src/dedup-key.ts`). Clients source
`target_language` from the canonical onboarding picker, so this is mostly a guard.

## Target-generation profiles (the allowlist)

- One `TargetGenerationProfile` per language the word layer can explain
  (`resolveTargetProfile`): identity (tag, prompt name), gating (`enabled`), the POS
  subset, and pronunciation display labels. The model-facing prompt/schema text per
  target lives with the provider (`backend/src/providers`), keyed by the profile tag.
- **Gating** (`isGenerationAllowed`): only an **enabled** profile generates — `en`,
  `zh-Hans`, and `ja` are live (each enabled after its own paid eval gate; adding a
  target is a server-authoritative profile + paid eval gate).
  A not-yet-enabled target is **saved + reviewable** but returns `language_unsupported` —
  refused server-side even if a client asks (the gate is server-authoritative; the
  anonymous device id is forgeable).
- **Keying** (`generationCacheKey`): the resolved profile's own tag. Region/variant
  tags collapse (`en-US`/`en-GB` → `en`) so the shared cache keyspace + AI spend stay
  bounded; script-sensitive profiles keep the script axis (`zh`/`zh-CN` → `zh-Hans`
  via likely-subtags; `zh-Hant` resolves to NO profile — it can never collide with
  `zh-Hans`).
- **Explanation-language** (`resolveExplanationLanguage` / `isSupportedExplanationLanguage`):
  the native gloss axis — nine languages: `en`, `es`, `de`, `it`, `fr`, `pt`, `zh-Hans`,
  `ja`, `ko`. This axis is independent of the three enabled generation targets. Region/locale
  tags resolve via likely-subtags — `en-US`→`en`, `es-MX`→`es`, `zh-CN`/`zh-SG`/bare
  `zh`→`zh-Hans`. Traditional Chinese (`zh-Hant`/`zh-TW`) is not supported.

## Run

```sh
bun test
```
