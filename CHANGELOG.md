# Changelog

All notable changes to the WetWijzer application are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the version numbers follow [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) as applied in `docs/VERSIONING_POLICY.md`.

Everything deployed before 1.0.0 was unversioned: that history is identified by commit SHA only (production ran `a35840fba9f44fe8e22079fbb30022410ef7bf3a` when versioning was adopted on 2026-10-18), and no earlier release is retroactively given a number.

A section's date is set when the candidate is sealed for review, and the sealed commit is deployed and tagged (`vX.Y.Z` on that exact SHA) without any change to its files; a dated section is therefore a planned release until the deployed SHA, its tag and its receipt say it shipped. If the day changes before the push, the candidate is re-sealed with the new date.

## [Unreleased]

## [1.0.0] - 2026-10-19

The first formally versioned release of a product already in production. Its scope is what root reviewed for it:

### Changed
- Chatbot billing: a question is charged its reserved price once a paid AI request for it was sent (question embedding, HyDE, generation and its retries, German translations) and released otherwise; an error, fence, lost claim or timeout after a paid request keeps exactly one charge, and the answer or error shown says so (`charge_notice` on code-only errors). The free-incomplete-search note is retired.
- A consent grant, even with the identical key pair, cancels the account's active conversation claims, so an answer or encrypted snapshot of the previous storage generation is never delivered or accepted.
- Explicit clear and delete of a conversation run under the account's storage gate, the same gate as the first paid dispatch of a question.
- Admin dashboard and analytics: research depth, model and thinking mode as recorded with each answer (never the stored tier, never a default), charges from the durable ledger, cost and revenue labelled as estimates with their coverage; the legacy intelligence tier stays as a labelled, unpriced view.
- Copy: the model tooltip, the FAQ entry on when a question is charged, the privacy banner's billing clause and the chatbot sidebar footer prompt.
- Internal: the repository's lint debt (964 rubocop offenses in 125 files, none from this release) repaired in reviewed batches with no behaviour change, the test suites of the German sites and the incomplete-provider copy aligned with the billing policy, and the EU corpus acquisition job split into bounded helpers under characterization tests; the committed exclude-only baseline, configuration and gates are unchanged.

### Added
- `billing_reservations.work_dispatched_at` and `work_dispatch_kind` (additive accounts migration `20261018100000`).
- `VERSION`, `WetWijzer::Version` and `WetWijzer::Release`, `version` in `GET /api/release`, the version in the site footer and the admin header, and `rake version:check`, `version:bump[level]`, `version:tag_check[sha]`.
