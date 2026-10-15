# Business questions Segpay (or any merchant-of-record payment processor) would care about

Use these to drive the dimensional model: for each question, ask what the grain, facts, dimensions and slowly-changing attributes must be.

## 1. Volume & revenue
1. Gross processed volume (USD) by month, vertical, merchant, currency. What's the trend and seasonality by vertical?
2. Segpay net revenue (fees earned) vs. gross volume: what is the effective **take rate** by merchant, vertical and risk tier? Where is it eroding?
3. How concentrated is revenue? Share from the top 10 merchants / top 10 sites; how has concentration changed?
4. New-sale vs. rebill vs. one-time mix over time. How much volume is recurring and how predictable is it?
5. What is the FX exposure: volume by currency, and the USD impact of rate moves on non-USD merchants?

## 2. Authorization & decline performance
6. Approval rate by merchant, vertical, card brand, card type (credit/debit/prepaid), issuer country, 3-D Secure vs. not, device, hour of day. Where are we leaving money on the table?
7. Decline reasons: split into soft (retryable) vs. hard declines. Which response codes dominate by vertical?
8. Do retries recover revenue? Recovery rate by retry attempt/delay for initial sales and for rebills.
9. How do acquirers compare on approval rate and cost (interchange from clearing files) for the same card mix?
10. Is the approval rate changing after the gateway migration? Is that a real change or a data artefact?

## 3. Subscription health
11. Trial-to-paid conversion by package, merchant, traffic source, promo code.
12. Rebill success rate by billing cycle number. Where's the cliff (cycle 1? annual renewals?)
13. Retention curves / cohort survival by signup month, package type (monthly vs. quarterly vs. annual) and vertical.
14. Involuntary vs. voluntary churn: share of cancellations that are payment failures vs. consumer/merchant/support-initiated; top cancel reasons by vertical.
15. Estimated MRR/ARR by merchant, and net revenue retention of active subscribers.
16. Pricing: which price points and trial structures yield the best 90-day net revenue per acquired customer?

## 4. Risk, fraud & chargebacks
17. Chargeback ratio (by count and by amount) per merchant per month. Which merchants breach card-network monitoring thresholds, and how early would we have seen it?
18. Chargeback rate by reason code/category (fraud vs. consumer dispute vs. processing error), network, vertical.
19. Time from transaction to chargeback; representment win rate by reason code and by merchant; dollars recovered.
20. Does the risk engine work? Score distribution vs. eventual chargeback/refund outcome; rule-level precision; false-positive cost (good customers declined by the engine).
21. Which signals (IP/BIN mismatch, disposable email, prepaid BIN, VPN, device reuse) predict fraud best? Did the new risk-engine version improve things?
22. Do certain affiliates/traffic sources drive disproportionate fraud, early cancels or chargebacks? Rank affiliates by net quality, not volume.
23. Refund rate and time-to-refund by merchant/vertical. Are refunds precursors to chargebacks?

## 5. Merchant lifecycle & portfolio risk
24. Onboarding to first transaction time; merchants live but with no volume; merchants that grow vs. decay.
25. How have merchant risk tiers and reserve rates changed over time, and did the changes precede incidents? (needs history)
26. Which merchants were suspended/terminated, what did their metrics look like in the 90 days before?
27. Total reserve held vs. released; reserve adequacy relative to trailing chargeback + refund exposure.

## 6. Finance & operations
28. Settlement reconciliation: does gateway activity reconcile to settlement statements and to acquirer clearing files? Where are the breaks and what are they worth?
29. Payout performance: days from period end to payout, failed/returned payouts, held payouts and why.
30. Manual adjustments: size, frequency, who/why. Is any merchant getting repeated waivers?
31. Fee leakage: contracted fee schedule vs. fees actually charged.

## 7. Customer & support
32. Do support contacts predict chargebacks or churn? (e.g. "unrecognized charge" tickets that later became chargebacks: could we have refunded first?)
33. Repeat customers across sites/merchants; customers with multiple cards; customer geography vs. card-issuer country.
34. Support volume and CSAT by merchant/vertical; first-reply time vs. resolution.

## 8. Data-quality / governance (report these too: they're a real BI deliverable)
35. A data-quality scorecard per source: null rates, duplicates, orphan keys, referential breaks, late-arriving data, schema drift.
36. Which dimension attributes need history (SCD2) and which can be overwritten, and why?

## Suggested headline KPIs for the Power BI semantic model
Gross volume (USD) · Net revenue · Take rate · Approval rate (first attempt vs. incl. retries) · Soft-decline recovery rate · Rebill success rate · Trial conversion · 30/90-day retention · Voluntary vs. involuntary churn · Chargeback ratio (count & amount) · Refund rate · Fraud rate · Representment win rate · Reserve balance · Net payout · Reconciliation variance.
Remember that ratio KPIs need careful denominators and time-alignment (e.g. chargebacks are attributed to the original transaction month *and* the month received: both views matter).
