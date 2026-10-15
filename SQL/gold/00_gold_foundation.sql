/* =====================================================================
   Script    : 00_gold_foundation.sql
   Purpose   : Schema and reference data used by the gold layer.
               Safe to re-run (reference rows are upserted with MERGE).

   Requires the silver foundation (SQL\silver\00_foundation.sql) for the
   ref and audit schemas.

   Reference tables added here
   ---------------------------
     ref.response_code_class       - is each authorization response an
                                     approval, a soft decline (worth retrying)
                                     or a hard decline (do not retry)?
     ref.chargeback_monitoring_program - card-network chargeback monitoring
                                     thresholds used by the view
                                     gold.agg_chargeback_monitoring

   Both hold business rules as data: edit the rows, no code change
   needed. (Response codes reach gold on the next gold load; the
   chargeback view picks up program changes immediately.)
   ===================================================================== */
SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'gold') IS NULL EXEC (N'CREATE SCHEMA gold');
GO

/* =====================================================================
   ref.response_code_class
   ---------------------------------------------------------------------
   Soft decline : temporary - the same card may succeed later (e.g.
                  insufficient funds); rebill retries make sense.
   Hard decline : permanent for this card (expired, lost, invalid, fraud,
                  CVV failure) - retrying wastes attempts and can draw
                  network fines.
   General industry guidance; adjust to SegPay's own retry policy.
   ===================================================================== */
IF OBJECT_ID(N'ref.response_code_class', N'U') IS NULL
    CREATE TABLE ref.response_code_class (
        response_code   VARCHAR(10)  NOT NULL CONSTRAINT PK_ref_response_code_class PRIMARY KEY,
        response_group  VARCHAR(10)  NOT NULL,   -- Approved / Declined
        decline_type    VARCHAR(10)  NULL,       -- Soft / Hard (NULL for approvals)
        note            NVARCHAR(200) NULL
    );
GO
MERGE ref.response_code_class AS t
USING (VALUES
    ('00', 'Approved', NULL,   N'Approved'),
    ('05', 'Declined', 'Soft', N'Do not honor - generic; often succeeds on a later retry'),
    ('51', 'Declined', 'Soft', N'Insufficient funds - retry after payday'),
    ('61', 'Declined', 'Soft', N'Exceeds withdrawal limit - retry later'),
    ('91', 'Declined', 'Soft', N'Issuer unavailable - technical, retry'),
    ('96', 'Declined', 'Soft', N'System malfunction - technical, retry'),
    ('14', 'Declined', 'Hard', N'Invalid card number'),
    ('41', 'Declined', 'Hard', N'Lost card - pick up'),
    ('54', 'Declined', 'Hard', N'Expired card - needs new card details'),
    ('57', 'Declined', 'Hard', N'Transaction not permitted to cardholder'),
    ('59', 'Declined', 'Hard', N'Suspected fraud - do not retry'),
    ('62', 'Declined', 'Hard', N'Restricted card'),
    ('78', 'Declined', 'Hard', N'Blocked / no account'),
    ('N7', 'Declined', 'Hard', N'CVV2 / CVC2 failure - same details will fail again')
) AS s (response_code, response_group, decline_type, note)
ON t.response_code = s.response_code
WHEN MATCHED AND EXISTS (SELECT s.response_group, s.decline_type, s.note EXCEPT SELECT t.response_group, t.decline_type, t.note)
    THEN UPDATE SET response_group = s.response_group, decline_type = s.decline_type, note = s.note
WHEN NOT MATCHED THEN INSERT (response_code, response_group, decline_type, note)
                      VALUES (s.response_code, s.response_group, s.decline_type, s.note);
GO

/* =====================================================================
   ref.chargeback_monitoring_program
   ---------------------------------------------------------------------
   Card networks fine merchants whose chargebacks exceed a ratio AND a
   minimum count in a month. A merchant is in a program when, for that
   network and month:
       chargeback ratio >= min_ratio  AND  chargeback count >= min_count
   ratio_basis says how the network divides:
       same_month  : chargebacks this month / sales this month   (Visa style)
       prior_month : chargebacks this month / sales last month   (Mastercard style)
   severity orders the levels (higher = worse).
   min_sales_for_warning: the ratio-only early warning (ratio over the
       network's lowest threshold, whatever the count) is raised only when
       the sales the ratio divides by reach this number - 1 chargeback on
       1 sale is 100% but means nothing. Read from the lowest-severity row.

   !! The values below are approximations of the published programs for
      illustration. Networks change these rules (e.g. Visa replaced VDMP
      with VAMP in 2025). Confirm the current thresholds with the acquirers
      and update these rows. !!
   ===================================================================== */
IF OBJECT_ID(N'ref.chargeback_monitoring_program', N'U') IS NULL
    CREATE TABLE ref.chargeback_monitoring_program (
        network       VARCHAR(20)   NOT NULL,
        program_name  VARCHAR(60)   NOT NULL,
        severity      TINYINT       NOT NULL,
        ratio_basis   VARCHAR(11)   NOT NULL CONSTRAINT CK_ref_cb_program_basis CHECK (ratio_basis IN ('same_month', 'prior_month')),
        min_ratio     DECIMAL(9,6)  NOT NULL,   -- 0.009000 = 0.9%
        min_count     INT           NOT NULL,
        min_sales_for_warning INT   NOT NULL CONSTRAINT DF_ref_cb_program_min_sales DEFAULT 20,
        CONSTRAINT PK_ref_chargeback_monitoring_program PRIMARY KEY (network, program_name)
    );
GO
-- Added 2026-10-15 (was a load-procedure parameter before the summary became a view)
IF COL_LENGTH(N'ref.chargeback_monitoring_program', N'min_sales_for_warning') IS NULL
    ALTER TABLE ref.chargeback_monitoring_program
        ADD min_sales_for_warning INT NOT NULL CONSTRAINT DF_ref_cb_program_min_sales DEFAULT 20;
GO
MERGE ref.chargeback_monitoring_program AS t
USING (VALUES
    ('Visa',       'Early Warning',                     1, 'same_month',  0.006500,   75, 20),
    ('Visa',       'Dispute Monitoring - Standard',     2, 'same_month',  0.009000,  100, 20),
    ('Visa',       'Dispute Monitoring - Excessive',    3, 'same_month',  0.018000, 1000, 20),
    ('Mastercard', 'Chargeback Monitored Merchant',     1, 'prior_month', 0.015000,  100, 20),
    ('Mastercard', 'Excessive Chargeback Merchant',     2, 'prior_month', 0.015000,  100, 20),
    ('Mastercard', 'High Excessive Chargeback Merchant',3, 'prior_month', 0.030000,  300, 20)
) AS s (network, program_name, severity, ratio_basis, min_ratio, min_count, min_sales_for_warning)
ON t.network = s.network AND t.program_name = s.program_name
WHEN MATCHED AND EXISTS (SELECT s.severity, s.ratio_basis, s.min_ratio, s.min_count, s.min_sales_for_warning
                         EXCEPT SELECT t.severity, t.ratio_basis, t.min_ratio, t.min_count, t.min_sales_for_warning)
    THEN UPDATE SET severity = s.severity, ratio_basis = s.ratio_basis, min_ratio = s.min_ratio, min_count = s.min_count,
                    min_sales_for_warning = s.min_sales_for_warning
WHEN NOT MATCHED THEN INSERT (network, program_name, severity, ratio_basis, min_ratio, min_count, min_sales_for_warning)
                      VALUES (s.network, s.program_name, s.severity, s.ratio_basis, s.min_ratio, s.min_count, s.min_sales_for_warning);
GO
