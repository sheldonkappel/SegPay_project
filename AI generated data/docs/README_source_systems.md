# Segpay-style source system extracts (synthetic)

Fictional data for a payment processor / merchant-of-record serving subscription merchants (adult, dating, SaaS, gaming, streaming, nutra, e-learning, fitness).
Window: **Oct 2024 – 13 Oct 2026**. ~150 merchants, ~320 sites, ~1,100 packages, ~69k customers, ~66k purchases, ~230k gateway transaction rows.
No real card data: BIN + last 4 only. Regenerate any time with `generate_source_data.py` (fixed seed).

Treat this like a data hand-off from teams you can't easily ask questions: there is no data dictionary beyond what's below.
Profiling it yourself is the exercise.

| Folder | Source system | Format | What it holds |
|---|---|---|---|
| `crm/` | Merchant boarding CRM (history-style export) | CSV | Merchants (multiple versions per merchant), sites, affiliates, acquirer MIDs, legacy→new merchant id xref |
| `pricing/` | Pricing / package config system | pipe-delimited `.txt` | Packages: billing model, trial, rebill price & period |
| `billing/` | Subscription billing platform (legacy SQL dump) | TSV, PascalCase | Customers, purchases (current-state snapshot) |
| `txn/` | Payment gateway | monthly CSV | Every auth/sale/rebill/refund/void/chargeback event. **The gateway was migrated mid-project; expect the two eras to differ.** |
| `risk/` | Fraud / risk decision engine | JSON Lines | One decision event per initial attempt, with rules fired and signals |
| `disputes/` | Acquirer chargeback feed | quoted CSV | Chargeback cases from card networks |
| `finance/` | Finance / ERP | CSV | Weekly merchant settlements, daily FX rates |
| `support/` | Customer-support helpdesk | semicolon CSV | Support tickets |
| `affiliate_tracker/` | Third-party ad/affiliate click tracker | CSV | Clicks and conversions |
| `acquirer_clearing/` | Acquirer clearing files (3 acquirers) | monthly XML | What the acquirers say they cleared |
| `reference/` | Shared reference | CSV | BIN table, chargeback reason codes, response codes |

Suggested first steps: land everything as-is into a Bronze layer with load metadata, profile every column, then decide your keys, grain and conformed dimensions before touching Silver.
See `business_questions.md` for what the reporting layer should eventually answer.
