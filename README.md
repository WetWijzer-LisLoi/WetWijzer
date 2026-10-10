# WetWijzer

Open-source Belgian legal-research application for legislation, jurisprudence,
and parliamentary material. WetWijzer is a Ruby on Rails application with a
progressively enhanced interface: core search and reading flows are
server-rendered and usable without JavaScript; Turbo and Stimulus add optional
interactive and convenience features.

> This repository is a curated public code snapshot, not a self-contained
> production application or a hosted-service deployment guide.

## Brands and languages

One codebase serves four branded portals. A brand supplies a default locale;
readers may choose a supported interface language.

| Brand | Canonical domain | Default locale |
| --- | --- | --- |
| WetWijzer | `wetwijzer.be` | Dutch |
| LisLoi | `lisloi.be` | French |
| GesetzGuide | `gesetzguide.be` | German |
| LexLibera | `lexlibera.be` | English |

## What it does

- Searches legislation, jurisprudence, and parliamentary material, with
  filtering, sorting, and pagination.
- Presents legislation with article navigation, a table of contents, related
  references, and supported copy, comparison, and export actions.
- Browses case law by ECLI and parliamentary dossiers, documents, members, and
  hemicycle views.
- Includes a retrieval-backed legal chatbot that can show source citations.
  It is not legal advice and may be incomplete or wrong.
- Supports accounts, bookmarks, subscriptions/credits, two-factor
  authentication, data export, and account deletion.
- Provides responsive layouts, accessible keyboard controls, themes, PWA
  support, and a plain Classic presentation.

### Privacy-oriented preferences

Interface preferences for signed-in users, including theme choices, are stored
server-side rather than in `localStorage`. Browser-local bookmarks are a
separate visitor feature. Chat history is opt-in; the optional encrypted
history flow stores an encrypted payload rather than raw history content.
Consult the live service's privacy notices for current processing details.

## Architecture

```text
Browser
  ├─ Server-rendered HTML and progressive enhancement (Turbo / Stimulus)
  └─ Vite-built JavaScript and Tailwind styles
        │
Rails + Puma
  ├─ Legal-content, search, account, billing, and background-work domains
  ├─ SQLite legal-corpus lanes
  └─ Mutable account and analytics lanes, with PostgreSQL support
        │
Optional Python FAISS services for vector retrieval
```

The legal corpus is SQLite-based. Account and analytics data are isolated from
that corpus and can use PostgreSQL in deployments that enable the optional
adapter; repository configuration is the source of truth for the exact
database topology.

## Technology

- Ruby on Rails, Puma, and Solid Queue
- SQLite legal-data lanes; optional PostgreSQL mutable lanes
- Vite, Turbo, Stimulus, and Tailwind CSS
- Optional Python/FAISS vector-retrieval services

Resolved dependency versions belong in `Gemfile.lock` and `package-lock.json`,
not in this README.

## Billing

The application supports Free and Pro access plus credit purchases. Prices,
included credits, model eligibility, and feature availability are defined by
current application configuration and the pricing UI; this README deliberately
does not freeze a price or model matrix.

Mollie is the active hosted-checkout integration. An optional CoinGate path is
also present. Checkout is created by POST and fulfilment verifies provider
state before granting credits or access. Historical Stripe-named fields may
remain for audit compatibility; Stripe is not an active checkout integration.

Shared project backup and storage infrastructure is operational capacity, not
a customer entitlement, account quota, or advertised per-user storage plan.

## Praxis

The codebase contains optional, pre-release desktop-integration surfaces for
Praxis. They are not an availability promise or a supported product commitment.

## What this public snapshot omits

To keep the public repository safe and practical to inspect, it deliberately
excludes, among other things:

- legal-corpus databases and other production data;
- the test suites and a maintained, complete migration/deployment set (some
  historical migrations remain in the snapshot);
- private ingestion, backend, administration, and operational tooling; and
- legal-page material containing the operator's registered identity details.

As a result, a fresh clone is useful for code review and contribution-oriented
exploration, but is not sufficient to reproduce the live service. Do not add
credentials, webhook secrets, private addresses, or infrastructure-specific
configuration to issues, commits, or forks.

## License

MIT License. See [LICENSE.md](LICENSE.md).
