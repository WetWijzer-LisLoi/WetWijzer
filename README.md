# WetWijzer

**Open-source search engine for Belgian legislation, jurisprudence, and parliamentary preparatory works.**

WetWijzer (Dutch), LisLoi (French), and GesetzGuide (German) are three brands running from a single codebase — a trilingual Ruby on Rails application serving the Belgian legal community. The platform indexes **2.8 million+ articles** from the Belgian Official Gazette (Belgisch Staatsblad / Moniteur belge) and provides AI-powered legal Q&A through an integrated chatbot.

> **Live:** [wetwijzer.be](https://wetwijzer.be) | [lisloi.be](https://lisloi.be) | [gesetzguide.be](https://gesetzguide.be)

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Data Pipeline](#data-pipeline)
- [Features](#features)
- [AI Chatbot](#ai-chatbot)
- [FAISS Vector Search](#faiss-vector-search)
- [Theming](#theming)
- [Internationalization](#internationalization)
- [Monetization](#monetization)
- [Praxis Integration](#praxis-integration)
- [Admin Console](#admin-console)
- [Security](#security)
- [Infrastructure](#infrastructure)
- [Development Setup](#development-setup)
- [Testing](#testing)
- [Deployment](#deployment)
- [Project Structure](#project-structure)
- [Documentation](#documentation)
- [License](#license)

---

## Overview

WetWijzer is a legal information portal that makes Belgian legislation accessible, searchable, and understandable. It combines:

- **Full-text legislation search** across 280,000+ laws, decrees, ordinances, and constitutional texts
- **2.8M article-level indexing** with cross-references, modification tracking, and execution decrees
- **Jurisprudence search** via vector-based semantic retrieval (Court of Cassation, Constitutional Court, Council of State)
- **Parliamentary preparatory works** with MP directory and hemicycle visualization
- **AI legal assistant** powered by Azure OpenAI with multi-tier intelligence levels
- **FisconetPlus tax law integration** for Belgian income tax codes
- **Judge intelligence analytics** for ruling pattern analysis

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Client Browser                          │
│   Hotwire (Turbo + Stimulus)  ·  TailwindCSS 4  ·  Vite 8     │
└──────────────────────────┬──────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│                    Rails 8.1 (Puma)                             │
│  Controllers · Services · Models · ViewComponents · Mailers    │
│  SQLite (WAL mode) · Multi-DB (primary + accounts + analytics) │
└──────┬──────────────┬──────────────────┬───────────────────────┘
       │              │                  │
┌──────▼──────┐ ┌─────▼──────┐  ┌───────▼──────────┐
│ FAISS Python │ │ Azure      │  │ Stripe / Mollie  │
│ microservices│ │ OpenAI     │  │ (Payments)       │
│ (8 indexes)  │ │ (Sweden C) │  │                  │
└──────────────┘ └────────────┘  └──────────────────┘
```

### Multi-Database Architecture

| Database | Purpose | Key Tables |
|----------|---------|------------|
| **Primary** (SQLite) | Legislation, articles, references | `legislations`, `articles`, `contents`, `exdecs`, `document_number_lookups` |
| **Accounts** (SQLite) | Users, auth, subscriptions | `users`, `subscriptions`, `credit_purchases`, `account_activities` |
| **Analytics** (SQLite) | Chatbot usage, metrics | `chatbot_analytics`, `chatbot_conversations`, `chatbot_feedbacks` |
| **Jurisprudence** (SQLite) | Court cases | `court_cases`, `case_chunks` |

---

## Tech Stack

### Backend
| Component | Version | Purpose |
|-----------|---------|---------|
| Ruby | 4.0.5 | Language runtime |
| Rails | 8.1.3 | Web framework |
| SQLite | WAL mode | Database (multi-DB) |
| Puma | Latest | Application server |
| Python | 3.12+ | FAISS servers, scrapers, data enrichment |

### Frontend
| Component | Version | Purpose |
|-----------|---------|---------|
| Vite | 8.x | Build tool & dev server |
| Hotwire (Turbo) | 8.x | SPA-like page transitions |
| Stimulus | 3.x | JavaScript controllers (47 controllers) |
| Tailwind CSS | 4.3 | Utility-first CSS framework |
| SCSS | Via Sass | Theme engine & custom components |

### Key Gems
| Gem | Purpose |
|-----|---------|
| `turbo-rails` / `stimulus-rails` | Hotwire stack |
| `vite_rails` | Vite integration for asset pipeline |
| `pagy` | High-performance pagination |
| `view_component` | Encapsulated view components |
| `bcrypt` | Password hashing |
| `rotp` / `rqrcode` | 2FA (TOTP + QR codes) |
| `stripe` | Payment processing |
| `ruby-openai` | Azure OpenAI API client |
| `jwt` | Partner API authentication |
| `rack-attack` | Rate limiting & brute-force protection |

---

## Data Pipeline

The legislation database is built through a multi-stage Python scraping and enrichment pipeline:

```
Belgian Official Gazette (ejustice.just.fgov.be)
         │
         ▼
    Python Scrapers (scripts/)
    ├── scrape_updated_laws.py      → New/updated legislation
    ├── scrape_etaamb_references.py → Cross-references & modification links
    ├── scrape_arrestendatabank.py  → Jurisprudence (Court of Cassation)
    └── enrich_*.py                 → Embeddings, FTS indexes, metadata
         │
         ▼
    SQLite Databases
    ├── legislation.db  (280K+ laws, 2.8M+ articles)
    ├── jurisprudence.db (court cases)
    └── parliamentary.db (preparatory works)
         │
         ▼
    FAISS Indexes (vector embeddings)
    ├── articles (2.8M vectors)
    ├── articles_large (PQ-compressed)
    ├── jurisprudence
    ├── parliamentary
    ├── fisconet (tax law)
    ├── regional (Vlaamse Codex)
    └── soft_law (circulaires)
```

### Data Sources
- **Justel** (ejustice.just.fgov.be) — Federal legislation
- **ETaamb** — Cross-reference and modification data
- **Juportal** (juportal.be) — Jurisprudence database
- **Belgian Chamber** (dekamer.be) — Parliamentary documents
- **Vlaams Parlement** (vlaamsparlement.be) — Flemish parliament
- **FisconetPlus** (fisconet.fgov.be) — Tax legislation

---

## Features

### Legislation Search
- **Full-text search** with FTS5 across titles, article text, and abbreviation tags
- **Exact match** and **flexible match** modes
- **Advanced filters**: date range, year range, legislation type, language, NUMAC lookup
- **Popular laws** quick-access by legal domain (civil, criminal, corporate, tax, social, constitutional)
- **Article-level viewing** with collapsible table of contents and sidebar navigation
- **Cross-references**: modification links, execution decrees (uitvoeringsbesluiten), and reverse references
- **Copy/export**: clipboard with formatting, Word (.docx) export, clean citation mode
- **ELI redirect support** (European Legislation Identifier URLs)

### Jurisprudence
- Semantic vector search across court decisions
- ECLI-based URLs for stable case references
- Full-text display with GDPR pseudonymization
- Word export for court decisions

### Parliamentary Work
- Chamber documents with linked legislation
- MP directory with party affiliation and biography
- Hemicycle visualization (interactive seat chart)
- Vlaams Parlement integration

### Judge Intelligence
- Analytics on judge ruling patterns
- JSON API for integration with Praxis desktop app

### User Features
- **Bookmarks** (client-side, no login required)
- **Search alerts** (email notifications for new matching legislation)
- **Keyboard shortcuts** for power users
- **RSS feeds** for latest laws and search results
- **Copy reference** (full citation, short citation, legal citation, NUMAC, URL)
- **Dark mode** with 16 accent color themes

---

## AI Chatbot

The legal AI assistant uses a RAG (Retrieval-Augmented Generation) architecture:

```
User Question
    │
    ▼
FAISS Vector Search (find relevant articles/cases)
    │
    ▼
Context Assembly (system prompt + legal reference sheet + RAG results)
    │
    ▼
Azure OpenAI LLM (Sweden Central, GDPR-compliant)
    │
    ▼
Streaming Response with Source Citations
```

### Intelligence Tiers

| Tier | Model | Credits | Speed |
|------|-------|:---:|:---:|
| ⚡ Smart | GPT-5 Mini | 1 | ~2s |
| ⭐ Genius | GPT-5 | 3 | ~5s |
| 🏆 Mastermind | GPT-5 + reasoning | 5 | ~7s |
| 🔮 Omniscient | Claude Opus 4.8 | 8 | ~10s |

### Sources
The chatbot can query across multiple knowledge bases:
- **Legislation** — 2.8M articles from Belgian law
- **Jurisprudence** — Court decisions (Pro only)
- **Parliamentary work** — Preparatory documents (Pro only)
- **All sources** — Combined search

---

## FAISS Vector Search

Eight independent Python microservices serve vector similarity search:

| Service | Port | Index Size | Purpose |
|---------|------|-----------|---------|
| `faiss_articles_server` | 5001 | ~280K | Legislation titles/metadata |
| `faiss_articles_large_server` | 5002 | ~2.8M | Full article text (PQ-compressed) |
| `faiss_jurisprudence_server` | 5003 | Variable | Court decisions |
| `faiss_parliamentary_server` | 5004 | Variable | Parliamentary documents |
| `faiss_fisconet_server` | 5005 | Variable | Tax legislation |
| `faiss_regional_server` | 5006 | Variable | Vlaamse Codex |
| `faiss_soft_law_server` | 5007 | Variable | Circulaires & soft law |
| `faiss_eu_caselaw_server` | 5008 | Variable | EU case law (CJEU) |

Each server runs as a systemd service with a shared base class (`faiss_base_server.py`) providing health checks, caching, and graceful error handling.

---

## Theming

WetWijzer supports **16 accent color themes** with full dark/light mode support:

- **Engine**: SCSS variables in `app/javascript/stylesheets/themes/_accent.scss`
- **Switching**: Stimulus controller (`theme_selector_controller.js`) with `localStorage` persistence
- **Variants**: Each theme defines `--accent-{50..900}` for text/borders and `--accent-{400..700}-solid` for backgrounds with white text
- **Dark mode**: `prefers-color-scheme` media query + manual toggle via `dark_mode_controller.js`

Available themes: Original (teal), Blue, Rose, Amber, Emerald, Violet, Fuchsia, Pink, Slate, Indigo, Sky, Teal, Cyan, Green, Purple, Red.

---

## Internationalization

The application runs as three distinct brands from one codebase:

| Domain | Brand | Language | Locale File |
|--------|-------|----------|-------------|
| wetwijzer.be | WetWijzer | Dutch (NL) | `config/locales/nl.yml` |
| lisloi.be | LisLoi | French (FR) | `config/locales/fr.yml` |
| gesetzguide.be | GesetzGuide | German (DE) | `config/locales/de.yml` |

Brand detection is automatic via the `Host` header. Each brand has its own:
- Favicon, app title, meta descriptions
- UI labels, error messages, email templates
- Legal pages (terms, privacy, imprint, accessibility)
- AI chatbot prompts and responses

---

## Monetization

### WetWijzer Subscription Tiers

| Tier | Price | AI Access |
|------|-------|-----------|
| **Free** | €0 | 3 credits/week (Smart only) |
| **Pro** | €2.99/mo or €29.90/yr | 30 credits/mo, all 4 intelligence tiers, jurisprudence |

### Credit Packs (Pay-As-You-Go)
| Pack | Credits | Price |
|------|---------|-------|
| Small | 10 | €1.00 |
| Medium | 30 | €2.50 |
| Large | 100 | €7.50 |

### Payment Processing
- **Stripe** for recurring subscriptions and one-time credit purchases
- **Mollie** planned as dual provider for Belgian market
- **PEPPOL** e-invoicing compliance (mandatory for Belgian B2B since Jan 2026)
- **Octopus** accounting integration for invoice sync

---

## Praxis Integration

WetWijzer serves as the legal research backend for [Praxis Legal](https://praxislegal.be), a desktop practice management suite for Belgian lawyers.

### Partner API
- **JWT-authenticated** REST API (`/api/partner/*`)
- HMAC service authentication for server-to-server calls
- Endpoints: chatbot queries, saved answers, question history, bookmark sync
- Usage tracked separately as `request_source: 'partner'`

### SSO
- Magic link authentication from Praxis desktop → WetWijzer web
- Automatic account creation/linking on first SSO login

### Cross-Sell
- Praxis banner on WetWijzer profile page (light gold / dark navy themes)
- "Powered by WetWijzer" in Praxis AI Assistant

---

## Admin Console

Accessible via `admin.wetwijzer.be` (production) or `/admin` path (staging):

- **Dashboard** — Key metrics, active users, revenue
- **User management** — View/create users, manage credits, lock/unlock, tier changes
- **Chatbot analytics** — Query volume, model usage, cost tracking, P&L per tier
- **Invoice management** — Generate, send, export (PDF/XML), Octopus sync
- **Report moderation** — Review flagged chatbot responses

---

## Security

- **Authentication**: `bcrypt` password hashing, session-based auth with secure cookies
- **2FA**: TOTP via `rotp` with QR code setup and backup codes
- **Rate limiting**: `rack-attack` with progressive lockout (5 failed attempts → 15min lock)
- **GDPR compliance**: Data export (JSON), account deletion with 30-day grace period, pseudonymization
- **GDPR takedown**: Public form for Art. 17 right-to-erasure requests
- **Security headers**: HSTS, X-Frame-Options, CSP, X-Content-Type-Options
- **Dependency auditing**: `bundler-audit` and `brakeman` in CI

---

## Infrastructure

### Production
| Component | Provider | Spec |
|-----------|----------|------|
| **WetWijzer VPS** | Hetzner Cloud | CAX11 (2 vCPU ARM, 4GB RAM) |
| **Praxis Server** | Hetzner Cloud | CX23 (2 vCPU, 4GB RAM) |
| **Storage** | Hetzner Storage Box | BX11 (1TB) per account |
| **DNS** | AWS Route 53 → Hetzner | A/AAAA records |
| **Email** | Migadu | SMTP transactional mail |
| **SSL** | Let's Encrypt | Auto-renewed via Certbot |
| **AI** | Azure OpenAI | Sweden Central (GDPR) |
| **CDN/WAF** | Nginx | Reverse proxy with caching |

### Monitoring
- Umami Analytics (self-hosted, privacy-first)
- Application-level health checks (`/up`)
- FAISS service health endpoints (`/health`)

---

## Development Setup

### Prerequisites
- Ruby 4.0.5
- Node.js 26.2.0
- Python 3.12+ (for FAISS services)
- SQLite 3.x

### Quick Start

```bash
# Clone the repository
git clone <repository-url>
cd wetwijzer

# Install Ruby dependencies
bundle install

# Install Node dependencies
npm install

# Configure environment
cp .env.example .env
# Edit .env with your Azure OpenAI keys, Stripe keys, etc.

# Setup database
bin/rails db:setup

# Start development server (Rails + Vite)
bin/dev
# Or separately:
bin/rails server          # Rails on port 3000
npm run dev               # Vite dev server
```

### FAISS Services (Optional)

```bash
cd faiss_service
python -m venv venv
source venv/bin/activate  # or venv\Scripts\activate on Windows
pip install -r requirements.txt

# Start individual FAISS servers
python faiss_articles_server.py
python faiss_jurisprudence_server.py
# etc.
```

### Environment Variables

See `.env.example` for all configuration options:
- `CHATBOT_ENABLED` — Feature flag for AI chatbot (default: `false`)
- `AZURE_OPENAI_KEY` / `AZURE_OPENAI_ENDPOINT` — AI model access
- `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` — Payment processing
- `SMTP_USERNAME` / `SMTP_PASSWORD` — Transactional email (Migadu)
- `PARTNER_JWT_SECRET` — Praxis partner API authentication

---

## Testing

```bash
# Run Rails test suite
bin/rails test

# Run system tests (requires Chrome/Chromium)
bin/rails test:system

# Security audit
bundle exec bundler-audit check
bundle exec brakeman -q

# Lint
bundle exec rubocop
```

### Test Infrastructure
- **Unit tests**: Rails test framework
- **System tests**: Capybara + Cuprite (headless Chrome)
- **Controller tests**: `rails-controller-testing`
- **Security**: Brakeman (static analysis), Bundler-audit (dependency vulnerabilities)

---

## Deployment

### Staging (Automatic)

```bash
git push staging main
# → post-receive hook triggers deploy automatically
# → Bundle install, DB migrate, asset precompile, Puma restart
```

### Production

```bash
# Via deployment script
./deploy.ps1 production

# Or manual
git push production main
```

### Post-Deploy

The `post-receive` git hook on the server handles:
1. `bundle install --without development:test`
2. `bin/rails db:migrate`
3. SQLite PRAGMA configuration (WAL mode, busy timeout)
4. Puma restart via systemd

---

## Project Structure

```
wetwijzer/
├── app/
│   ├── components/          # ViewComponent classes
│   ├── controllers/         # 22 controllers + admin/ + api/ + webhooks/
│   ├── helpers/             # View helpers
│   ├── javascript/
│   │   ├── controllers/     # 47 Stimulus controllers
│   │   ├── components/      # JS components
│   │   ├── entrypoints/     # Vite entry points
│   │   ├── stylesheets/     # SCSS (application.scss + themes/)
│   │   └── utils/           # Shared JS utilities
│   ├── jobs/                # Background jobs
│   ├── mailers/             # Email templates (user, admin, invoice, GDPR)
│   ├── middleware/          # Rack middleware
│   ├── models/              # 31 models across 3 databases
│   ├── services/            # 17 service objects (chatbot, search, scraping)
│   └── views/               # 27 view directories (ERB templates)
├── config/
│   ├── locales/             # NL, FR, DE translations
│   ├── routes.rb            # 287 lines of routing
│   └── initializers/        # App configuration
├── db/
│   ├── migrate/             # Primary DB migrations
│   ├── accounts_migrate/    # Accounts DB migrations
│   ├── analytics_migrate/   # Analytics DB migrations
│   └── jurisprudence_migrate/ # Jurisprudence DB migrations
├── docs/                    # 190+ documentation files
├── faiss_service/           # 8 Python FAISS vector search servers
├── scripts/                 # Data pipeline scripts (Python)
├── deploy/                  # Deployment configurations
├── spec/ & test/            # Test suites
└── public/                  # Static assets, images, legal pages
```

---

## Documentation

Extensive documentation is available in the `docs/` directory (190+ files), organized by topic:

| Category | Key Documents |
|----------|--------------|
| **Architecture** | `architecture.md`, `chatbot-architecture.md`, `search-architecture.md` |
| **Data** | `data-models.md`, `data-pipeline.md`, `database-architecture.md` |
| **Development** | `development-guide.md`, `frontend-architecture.md`, `component-inventory.md` |
| **Deployment** | `deployment-guide.md`, `SERVER_ARCHITECTURE.md`, `HETZNER_INFRASTRUCTURE.md` |
| **Security** | `security-architecture.md`, `SERVER_SECURITY.md`, `SECURITY_AUDIT_2026-01-19.md` |
| **AI/Chatbot** | `chatbot_architecture.md`, `CHATBOT_TIERS.md`, `chatbot_decomposition_architecture.md` |
| **Business** | `commercial_model.md`, `business-logic.md`, `PRAXIS_INTEGRATION.md` |
| **GDPR** | `JURISPRUDENCE_GDPR_ANALYSIS.md`, `JURISPRUDENCE_DPIA.md`, `gdpr_pseudonymization_audit_may_2026.md` |

---

## License

MIT License. See [LICENSE.md](LICENSE.md) for details.

Copyright (c) 2025 WetWijzer / LisLoi Contributors.
