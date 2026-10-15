# SegPay Data Warehouse

One trusted place to answer business questions about SegPay's payment processing: how much we process, how much we earn, how often payments are approved, and which merchants are at risk from chargebacks.

> The data in this project is synthetic. It imitates the data a payment processor receives from its systems and partners. It contains no real customers or card numbers.

---

## The problem it solves

SegPay's data arrives from **11 different systems**, each in its own format and with its own quirks:

- The payment gateway was replaced partway through, so transactions come in two different layouts.
- Dates are written several ways ("03/04/2025": March 4 or April 3?).
- Countries, card brands and acquirers are spelled differently from file to file.
- Refunds sometimes appear as "(67.95)" instead of "-67.95".
- Test merchants and test sites are mixed in with real activity.
- Merchant records are exported as several copies, one per change.

Reporting directly from these files gives different answers depending on who builds the report. The warehouse cleans and combines the data **once**, the same way every time, so everyone works from the same numbers.

---

## How the data flows

The warehouse uses the industry-standard **bronze → silver → gold** design. Each layer has one job, and data moves through them in order.

```mermaid
flowchart LR
    subgraph SRC["Source systems"]
        direction TB
        S1["Payment gateway<br/>(old and new)"]
        S2["Merchant CRM"]
        S3["Billing platform"]
        S4["Risk engine"]
        S5["Chargeback feed"]
        S6["Finance, acquirers,<br/>affiliates, support,<br/>reference lists"]
    end

    B["🥉 BRONZE<br/><b>Raw copy</b><br/>Every file kept<br/>exactly as received"]
    S["🥈 SILVER<br/><b>Clean data</b><br/>Fixed, standardized,<br/>de-duplicated"]
    G["🥇 GOLD<br/><b>Business-ready</b><br/>Organized for<br/>reporting"]
    R["📊 Reports<br/>Power BI, Excel,<br/>analysis"]

    SRC --> B --> S --> G --> R
```

| Layer | Think of it as… | What happens here | Who uses it |
|---|---|---|---|
| 🥉 **Bronze** | The filing cabinet | Every source file is stored exactly as it arrived, with a note of when it was loaded and from which file. Nothing is changed, so we can always go back to the original. | Data team (audits, investigations) |
| 🥈 **Silver** | The cleaned-up records | Data is corrected and made consistent: real dates and amounts, one spelling per country or card brand, duplicates and test data removed, both gateways combined into one transaction list. | Data team, analysts with detailed questions |
| 🥇 **Gold** | The reporting shelf | Data is organized around business questions, with all amounts in US dollars and history kept where it matters. | Business users, dashboards |

---

## What happens in each layer

### 🥉 Bronze: keep the original

```mermaid
flowchart LR
    F1["transactions_202501.csv"] --> T1["bronze.txn_pre_migration"]
    F2["merchants_crm_export.csv"] --> T2["bronze.merchants_crm_export"]
    F3["risk_events_202501.jsonl"] --> T3["bronze.risk_events"]
    F4["…21 sources in all"] --> T4["…one table per source"]
```

- One table per source. Every value is stored as text, just as received.
- Each row records **which file it came from** and **when it was loaded**.
- Loading the same file again doesn't create duplicates.

### 🥈 Silver: fix and standardize

```mermaid
flowchart LR
    subgraph IN["Raw (bronze)"]
        direction TB
        A1["'03/04/2025', '2025-04-03'"]
        A2["'(67.95)'"]
        A3["'USA', 'U.S.', 'United States'"]
        A4["Old gateway + new gateway<br/>(different layouts)"]
        A5["Test merchants mixed in"]
    end
    subgraph OUT["Clean (silver)"]
        direction TB
        B1["2025-04-03 (a real date)"]
        B2["-67.95 (a real amount)"]
        B3["US"]
        B4["One transaction table<br/>+ amount in USD"]
        B5["Test data removed<br/>(and counted)"]
    end
    A1 --> B1
    A2 --> B2
    A3 --> B3
    A4 --> B4
    A5 --> B5
```

The main fixes in silver:

- **Dates and times:** every date format is read correctly. The old gateway recorded US Eastern time, so its times are converted to UTC to match the new one.
- **Money:** amounts become numbers, and every amount also gets a **US-dollar value** using that day's exchange rate (or the latest rate before it).
- **Consistent names:** one spelling for each country, card brand, acquirer and status.
- **Missing values stay empty:** a missing value is left blank, never filled with "N/A" or 0, so it can't distort averages or totals.
- **Duplicates and test data are removed.** Every load records how many rows were removed and why.
- **Personal data is protected:** emails, IP addresses and postal codes are masked for anyone without permission to see them.

Every fix, source by source, is listed in [Data and Transformations in Detail](DATA_DETAILS.md).

### 🥇 Gold: organize for reporting

Gold uses a **star schema**, the standard layout for business reporting. Each event (a payment or a chargeback) sits in the middle and links to the things that describe it.

```mermaid
flowchart TB
    FT(["💳 Transactions<br/>every payment event"])
    FC(["⚠️ Chargebacks<br/>every dispute"])

    D1["📅 Date"]
    D2["🏢 Merchant<br/>(with history)"]
    D3["🌐 Site"]
    D4["📦 Package"]
    D5["👤 Customer"]
    D6["🤝 Affiliate"]
    D7["💳 Card type<br/>(BIN)"]
    D8["✅ Response code<br/>(approved / soft / hard decline)"]
    D9["📋 Chargeback reason"]
    D10["🏦 Merchant account"]

    D1 --- FT
    D2 --- FT
    D3 --- FT
    D4 --- FT
    D5 --- FT
    D6 --- FT
    D7 --- FT
    D8 --- FT
    D10 --- FT

    D1 --- FC
    D2 --- FC
    D9 --- FC
    D7 --- FC
    D10 --- FC

    FT --> CM[["📈 Chargeback monitoring<br/>ratio per merchant, network, month"]]
    FC --> CM
```

- **Facts** (the circles) are the things that happen: transactions and chargebacks, with their amounts.
- **Dimensions** (the boxes) are the ways you slice them: by date, merchant, card type and so on.
- **Merchant history is kept.** If a merchant's risk tier or pricing changes, the old version is kept. A sale from March is reported against the risk tier the merchant had in March, not today's. (History starts from 2026-10-15, when the warehouse went live.)
- **Nothing silently disappears.** If a transaction refers to a site or package we have no record of, it is shown under **"Unknown"** instead of being dropped from the totals.

---

## By the numbers

| | Raw (bronze) | Clean (silver) | Reporting (gold) |
|---|---|---|---|
| Payment transactions | 231,399 rows (two gateway formats) | 229,389 (one combined table) | 229,389 |
| Merchants | 419 rows (one copy per change) | 156 merchants | 156 merchants, with change history |
| Customers | 69,019 | 69,019 | 69,019 (no personal details) |
| Chargebacks | 877 | 877 | 877 |

Gold totals are checked against silver on every build: **$7.38M** in transaction value, **$5.73M** in approved sales and rebills, and **$28.7K** in chargebacks, matching to the cent.

---

## Questions it answers today

| Area | Example questions |
|---|---|
| **Volume and revenue** | What did we process this month, by merchant, vertical or currency? How much is new sales vs. rebills? |
| **Approvals and declines** | What share of payments are approved, by card brand, card type or issuer country? Which declines are worth retrying (soft) and which are not (hard)? |
| **Chargebacks** | Which merchants are close to the Visa or Mastercard monitoring thresholds, and in which month? How long after the sale do disputes arrive, and how many do we win? |

### Coming next

- **Subscription health:** trial-to-paid conversion, rebill success, retention and churn
- **Finance:** do gateway, settlement statements and acquirer clearing files agree?
- **Affiliate quality:** which traffic sources bring fraud or chargebacks?
- **Risk engine:** does the risk score predict chargebacks? Which rules work?
- **Support:** do support tickets predict chargebacks or churn?

---

## Keeping it up to date

A single command refreshes everything, in order:

```mermaid
flowchart LR
    A["New files arrive"] --> B["Load into bronze"] --> C["Rebuild silver<br/>(~1 min)"] --> D["Refresh gold<br/>(~10 sec)"] --> E["Reports show<br/>new data"]
```

```powershell
& ".\PowerShell scripts\Load-All.ps1" -LoadGold
```

Every step is logged: start and end time, rows loaded, rows removed and why, and any error. If a step fails, the steps after it don't run, so reports keep showing the last good data instead of half-loaded data.

---

## Good to know

- **Chargeback thresholds are examples.** The Visa and Mastercard monitoring limits in the warehouse are approximations for illustration. Confirm the current rules with the acquirers before acting on the warnings.
- **Known data issue:** 12 sites appear to be linked to the wrong merchant in the CRM (merchants MRC-00201 to MRC-00205). They are loaded as received until the business confirms the correct owner.
- **Data quality gaps show as "Unknown":** for example, about 18,000 transactions use a card BIN that isn't in the reference list, and 123 chargebacks have an unrecognized reason code. These are gaps in the source data, not loading errors.

---

## Project folders

| Folder | Contents |
|---|---|
| `AI generated data\` | The source files (not stored in GitHub) |
| `PowerShell scripts\` | The loader that brings files into bronze and runs every layer |
| `SQL\bronze`, `SQL\silver`, `SQL\gold` | The database code for each layer, each with its own technical README |
| `logs\` | A log of every refresh (not stored in GitHub) |

**Want more detail?** [Data and Transformations in Detail](DATA_DETAILS.md) describes every source file, the problems found in each, how each is cleaned, how many rows are kept or removed and why, and the known data issues.

Technical details for developers are in [SQL/README.md](SQL/README.md).
