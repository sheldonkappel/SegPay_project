/* =====================================================================
   Procedure : gold.usp_load_dim_merchant
   Source    : silver.merchants_crm_export (plus merchant IDs referenced
               elsewhere in silver but missing from the CRM)
   Target    : gold.dim_merchant   (slowly changing dimension, type 2)
   Load type : Incremental - versions are added and closed, never deleted.

   Purpose
   -------
   One row per merchant version, so a fact can be reported against the
   merchant's attributes at the time it happened (e.g. the risk tier and
   fees in force in March, not today's).

   How history is kept
   -------------------
     Tracked (a change creates a new version):
         vertical, status, risk_tier, reserve_pct, processing_fee_pct,
         per_txn_fee, chargeback_fee, mcc
     Overwritten on every version (corrections, not history):
         legal_name, dba_name, country, onboard_date, account_manager

     * New merchant         : first version valid_from 1900-01-01, so every
                              historical fact finds it.
     * Tracked attribute changed:
                              current version closed (valid_to = yesterday,
                              is_current = 0) and a new version opened
                              (valid_from = today). A second change on the
                              same day updates today's version in place.
     * Merchant referenced by transactions, sites, etc. but not in the CRM:
                              inserted as an inferred member (is_inferred = 1,
                              attributes NULL); filled in when the CRM sends it.
     * Merchant gone from the CRM: is_deleted = 1 (rows are kept).
     * merchant_key -1       : Unknown.

   Silver holds only the latest CRM record, so history accumulates from the
   first gold load (2026-10-15) onward.

   Usage
   -----
     EXEC gold.usp_load_dim_merchant;
   ===================================================================== */
CREATE OR ALTER PROCEDURE gold.usp_load_dim_merchant
    @run_id UNIQUEIDENTIFIER = NULL     -- set by gold.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName   SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target     SYSNAME      = N'gold.dim_merchant',
            @StartedAt  DATETIME2(3) = SYSUTCDATETIME(),
            @Today      DATE         = CAST(SYSUTCDATETIME() AS DATE),
            @Source     INT,
            @New        INT = 0,
            @Versioned  INT = 0,
            @SameDay    INT = 0,
            @Type1      INT = 0,
            @Resolved   INT = 0,
            @Deleted    INT = 0,
            @Restored   INT = 0,
            @Inferred   INT = 0,
            @Total      INT,
            @Metrics    NVARCHAR(MAX),
            @Err        NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'gold.dim_merchant does not exist - run SQL\gold\01_gold_tables.sql first.', 1;

        /* -------------------------------------------------------------
           Source: CRM merchants + inferred merchants referenced elsewhere
           ------------------------------------------------------------- */
        SELECT merchant_id, legal_name, dba_name, vertical, country, onboard_date, status, risk_tier,
               reserve_pct, processing_fee_pct, per_txn_fee, chargeback_fee, mcc, account_manager,
               CAST(0 AS BIT) AS is_inferred
        INTO #src
        FROM silver.merchants_crm_export;

        INSERT #src (merchant_id, is_inferred)
        SELECT DISTINCT x.merchant_id, 1
        FROM (SELECT merchant_id FROM silver.transactions
              UNION SELECT merchant_id FROM silver.merchant_accounts
              UNION SELECT merchant_id FROM silver.sites
              UNION SELECT merchant_id FROM silver.purchases_snapshot
              UNION SELECT merchant_id FROM silver.settlements_weekly
              UNION SELECT merchant_id FROM silver.chargebacks_acquirer_feed) x
        WHERE x.merchant_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM silver.merchants_crm_export c WHERE c.merchant_id = x.merchant_id);

        SELECT @Source = COUNT(*) FROM #src WHERE is_inferred = 0;

        BEGIN TRAN;

        -- Unknown member
        IF NOT EXISTS (SELECT 1 FROM gold.dim_merchant WHERE merchant_key = -1)
        BEGIN
            SET IDENTITY_INSERT gold.dim_merchant ON;
            INSERT gold.dim_merchant (merchant_key, merchant_id, legal_name, dba_name, valid_from, valid_to, is_current, load_run_id)
            VALUES (-1, 'Unknown', N'Unknown', N'Unknown', '19000101', '99991231', 1, @run_id);
            SET IDENTITY_INSERT gold.dim_merchant OFF;
        END

        /* 1. Inferred members that now have CRM data: fill them in place */
        UPDATE d
        SET legal_name = s.legal_name, dba_name = s.dba_name, vertical = s.vertical, country = s.country,
            onboard_date = s.onboard_date, status = s.status, risk_tier = s.risk_tier, reserve_pct = s.reserve_pct,
            processing_fee_pct = s.processing_fee_pct, per_txn_fee = s.per_txn_fee, chargeback_fee = s.chargeback_fee,
            mcc = s.mcc, account_manager = s.account_manager, is_inferred = 0,
            updated_at = SYSUTCDATETIME(), load_run_id = @run_id
        FROM gold.dim_merchant d
        JOIN #src s ON s.merchant_id = d.merchant_id AND s.is_inferred = 0
        WHERE d.is_inferred = 1;
        SET @Resolved = @@ROWCOUNT;

        /* 2. Overwritten attributes: correct every version */
        UPDATE d
        SET legal_name = s.legal_name, dba_name = s.dba_name, country = s.country,
            onboard_date = s.onboard_date, account_manager = s.account_manager,
            updated_at = SYSUTCDATETIME(), load_run_id = @run_id
        FROM gold.dim_merchant d
        JOIN #src s ON s.merchant_id = d.merchant_id AND s.is_inferred = 0
        WHERE EXISTS (SELECT s.legal_name, s.dba_name, s.country, s.onboard_date, s.account_manager
                      EXCEPT
                      SELECT d.legal_name, d.dba_name, d.country, d.onboard_date, d.account_manager);
        SET @Type1 = @@ROWCOUNT;

        /* 3. Tracked attributes changed on the current version */
        SELECT d.merchant_key, d.valid_from, s.*
        INTO #changed
        FROM gold.dim_merchant d
        JOIN #src s ON s.merchant_id = d.merchant_id AND s.is_inferred = 0
        WHERE d.is_current = 1 AND d.is_inferred = 0 AND d.merchant_key <> -1
          AND EXISTS (SELECT s.vertical, s.status, s.risk_tier, s.reserve_pct, s.processing_fee_pct, s.per_txn_fee, s.chargeback_fee, s.mcc
                      EXCEPT
                      SELECT d.vertical, d.status, d.risk_tier, d.reserve_pct, d.processing_fee_pct, d.per_txn_fee, d.chargeback_fee, d.mcc);

        -- 3a. Already versioned today: update today's version in place
        UPDATE d
        SET vertical = c.vertical, status = c.status, risk_tier = c.risk_tier, reserve_pct = c.reserve_pct,
            processing_fee_pct = c.processing_fee_pct, per_txn_fee = c.per_txn_fee, chargeback_fee = c.chargeback_fee,
            mcc = c.mcc, updated_at = SYSUTCDATETIME(), load_run_id = @run_id
        FROM gold.dim_merchant d
        JOIN #changed c ON c.merchant_key = d.merchant_key
        WHERE c.valid_from = @Today;
        SET @SameDay = @@ROWCOUNT;

        -- 3b. Close the current version ...
        UPDATE d
        SET valid_to = DATEADD(DAY, -1, @Today), is_current = 0,
            updated_at = SYSUTCDATETIME(), load_run_id = @run_id
        FROM gold.dim_merchant d
        JOIN #changed c ON c.merchant_key = d.merchant_key
        WHERE c.valid_from < @Today;

        -- ... and open the new one
        INSERT gold.dim_merchant (
            merchant_id, legal_name, dba_name, vertical, country, onboard_date, status, risk_tier, reserve_pct,
            processing_fee_pct, per_txn_fee, chargeback_fee, mcc, account_manager,
            valid_from, valid_to, is_current, is_inferred, load_run_id)
        SELECT merchant_id, legal_name, dba_name, vertical, country, onboard_date, status, risk_tier, reserve_pct,
               processing_fee_pct, per_txn_fee, chargeback_fee, mcc, account_manager,
               @Today, '99991231', 1, 0, @run_id
        FROM #changed
        WHERE valid_from < @Today;
        SET @Versioned = @@ROWCOUNT;

        /* 4. New merchants (CRM or inferred): first version covers all history */
        INSERT gold.dim_merchant (
            merchant_id, legal_name, dba_name, vertical, country, onboard_date, status, risk_tier, reserve_pct,
            processing_fee_pct, per_txn_fee, chargeback_fee, mcc, account_manager,
            valid_from, valid_to, is_current, is_inferred, load_run_id)
        SELECT s.merchant_id, s.legal_name, s.dba_name, s.vertical, s.country, s.onboard_date, s.status, s.risk_tier,
               s.reserve_pct, s.processing_fee_pct, s.per_txn_fee, s.chargeback_fee, s.mcc, s.account_manager,
               '19000101', '99991231', 1, s.is_inferred, @run_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM gold.dim_merchant d WHERE d.merchant_id = s.merchant_id);
        SET @New = @@ROWCOUNT;

        /* 5. Gone from the source -> flagged; back again -> unflagged */
        UPDATE d SET is_deleted = 1, updated_at = SYSUTCDATETIME(), load_run_id = @run_id
        FROM gold.dim_merchant d
        WHERE d.merchant_key <> -1 AND d.is_deleted = 0
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.merchant_id = d.merchant_id);
        SET @Deleted = @@ROWCOUNT;

        UPDATE d SET is_deleted = 0, updated_at = SYSUTCDATETIME(), load_run_id = @run_id
        FROM gold.dim_merchant d
        WHERE d.is_deleted = 1
          AND EXISTS (SELECT 1 FROM #src s WHERE s.merchant_id = d.merchant_id);
        SET @Restored = @@ROWCOUNT;

        COMMIT;

        SELECT SourceMerchants   = @Source,
               NewMerchants      = @New,
               NewVersions       = @Versioned,
               SameDayUpdates    = @SameDay,
               CorrectionsApplied = @Type1,
               InferredResolved  = @Resolved,
               FlaggedDeleted    = @Deleted,
               Restored          = @Restored,
               InferredMembers   = (SELECT COUNT(*) FROM gold.dim_merchant WHERE is_inferred = 1 AND is_current = 1),
               CurrentMerchants  = (SELECT COUNT(*) FROM gold.dim_merchant WHERE is_current = 1 AND merchant_key <> -1),
               TotalVersions     = (SELECT COUNT(*) FROM gold.dim_merchant WHERE merchant_key <> -1)
        INTO #summary;

        SELECT @Total = TotalVersions FROM #summary;
        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Succeeded', @rows_read = @Source, @rows_loaded = @Total, @metrics = @Metrics;

        SELECT * FROM #summary;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Err = ERROR_MESSAGE();
        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Failed', @error_message = @Err;
        THROW;
    END CATCH
END
GO
