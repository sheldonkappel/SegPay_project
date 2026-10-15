/* =====================================================================
   Script    : 03_gold_tests.sql
   Purpose   : Tests on the gold star schema: totals reconcile with silver,
               every fact row links to a dimension row, merchant history
               is consistent, and the summary view agrees with the facts.
   ===================================================================== */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   gold.fact_transaction reconciles with silver.transactions to the cent:
   row count, total USD value and approved revenue.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_gold_reconcile_transactions
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s_rows BIGINT, @s_usd DECIMAL(19,2), @s_rev DECIMAL(19,2),
            @g_rows BIGINT, @g_usd DECIMAL(19,2), @g_rev DECIMAL(19,2);

    SELECT @s_rows = COUNT(*), @s_usd = SUM(ISNULL(amount_usd, 0)),
           @s_rev  = SUM(CASE WHEN status = 'Approved' AND txn_type IN ('Sale', 'Rebill') THEN ISNULL(amount_usd, 0) ELSE 0 END)
    FROM silver.transactions;

    SELECT @g_rows = COUNT(*), @g_usd = SUM(ISNULL(amount_usd, 0)), @g_rev = SUM(ISNULL(revenue_usd, 0))
    FROM gold.fact_transaction;

    EXEC test.usp_assert_equal @s_rows, @g_rows, N'fact_transaction row count vs silver.transactions';
    EXEC test.usp_assert_equal @s_usd,  @g_usd,  N'fact_transaction total amount_usd vs silver';
    EXEC test.usp_assert_equal @s_rev,  @g_rev,  N'fact_transaction revenue_usd vs silver approved sales + rebills';
END
GO

/* ---------------------------------------------------------------------
   gold.fact_chargeback reconciles with silver.chargebacks_acquirer_feed.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_gold_reconcile_chargebacks
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s_rows BIGINT, @s_usd DECIMAL(19,2), @g_rows BIGINT, @g_usd DECIMAL(19,2);

    SELECT @s_rows = COUNT(*), @s_usd = SUM(dispute_amount_usd) FROM silver.chargebacks_acquirer_feed;
    SELECT @g_rows = COUNT(*), @g_usd = SUM(dispute_amount_usd) FROM gold.fact_chargeback;

    EXEC test.usp_assert_equal @s_rows, @g_rows, N'fact_chargeback row count vs silver';
    EXEC test.usp_assert_equal @s_usd,  @g_usd,  N'fact_chargeback total dispute_amount_usd vs silver';
END
GO

/* ---------------------------------------------------------------------
   Every dimension has its Unknown row (key -1), so facts with a missing
   reference still appear in reports.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_gold_unknown_members
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX), @missing NVARCHAR(2000), @n INT;

    CREATE TABLE #dim (dim SYSNAME, has_unknown INT);

    -- The key is the dimension's primary key column
    SELECT @sql = STRING_AGG(CAST(N'INSERT #dim SELECT N''' + t.name + N''', COUNT(*) FROM gold.' + QUOTENAME(t.name)
                                  + N' WHERE ' + QUOTENAME(c.name) + N' = -1;' AS NVARCHAR(MAX)), NCHAR(10))
    FROM sys.tables t
    JOIN sys.indexes i        ON i.object_id = t.object_id AND i.is_primary_key = 1
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal = 1
    JOIN sys.columns c        ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE t.schema_id = SCHEMA_ID(N'gold') AND t.name LIKE N'dim[_]%';

    EXEC sys.sp_executesql @sql;

    SELECT @n = COUNT(*), @missing = STRING_AGG(dim, N', ') FROM #dim WHERE has_unknown = 0;
    EXEC test.usp_assert_zero @n, N'dimensions without an Unknown (-1) row', @missing;
END
GO

/* ---------------------------------------------------------------------
   Every key in a fact table exists in its dimension (no orphans).
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_gold_no_orphan_keys
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX), @bad INT, @examples NVARCHAR(2000);

    CREATE TABLE #orphans (link NVARCHAR(300), n INT);

    SELECT @sql = STRING_AGG(CAST(N'INSERT #orphans SELECT N''' + f + N'.' + fk + N''', COUNT(*) FROM gold.' + f + N' x'
                                  + N' WHERE NOT EXISTS (SELECT 1 FROM gold.' + d + N' y WHERE y.' + dk + N' = x.' + fk + N');'
                                  AS NVARCHAR(MAX)), NCHAR(10))
    FROM (VALUES
        ('fact_transaction', 'date_key',              'dim_date',              'date_key'),
        ('fact_transaction', 'merchant_key',          'dim_merchant',          'merchant_key'),
        ('fact_transaction', 'merchant_account_key',  'dim_merchant_account',  'merchant_account_key'),
        ('fact_transaction', 'site_key',              'dim_site',              'site_key'),
        ('fact_transaction', 'package_key',           'dim_package',           'package_key'),
        ('fact_transaction', 'customer_key',          'dim_customer',          'customer_key'),
        ('fact_transaction', 'affiliate_key',         'dim_affiliate',         'affiliate_key'),
        ('fact_transaction', 'card_bin_key',          'dim_card_bin',          'card_bin_key'),
        ('fact_transaction', 'response_code_key',     'dim_response_code',     'response_code_key'),
        ('fact_chargeback',  'received_date_key',     'dim_date',              'date_key'),
        ('fact_chargeback',  'orig_txn_date_key',     'dim_date',              'date_key'),
        ('fact_chargeback',  'resolution_date_key',   'dim_date',              'date_key'),
        ('fact_chargeback',  'merchant_key',          'dim_merchant',          'merchant_key'),
        ('fact_chargeback',  'merchant_account_key',  'dim_merchant_account',  'merchant_account_key'),
        ('fact_chargeback',  'chargeback_reason_key', 'dim_chargeback_reason', 'chargeback_reason_key'),
        ('fact_chargeback',  'card_bin_key',          'dim_card_bin',          'card_bin_key'),
        ('fact_chargeback',  'site_key',              'dim_site',              'site_key'),
        ('fact_chargeback',  'package_key',           'dim_package',           'package_key'),
        ('fact_chargeback',  'customer_key',          'dim_customer',          'customer_key'),
        ('fact_chargeback',  'affiliate_key',         'dim_affiliate',         'affiliate_key')
    ) k (f, fk, d, dk);

    EXEC sys.sp_executesql @sql;

    SELECT @bad = SUM(n), @examples = STRING_AGG(CONCAT(link, N': ', n), N'; ') FROM #orphans WHERE n > 0;
    EXEC test.usp_assert_zero @bad, N'fact rows whose key has no dimension row', @examples;
END
GO

/* ---------------------------------------------------------------------
   Every fact row has a real date and a real merchant (not Unknown).
   The silver loads fill both for every row, so an Unknown here means a
   join broke.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_gold_no_unknown_date_or_merchant
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT;

    SELECT @n = COUNT(*) FROM gold.fact_transaction WHERE date_key = -1 OR merchant_key = -1;
    EXEC test.usp_assert_zero @n, N'transactions with an Unknown date or merchant';

    SELECT @n = COUNT(*) FROM gold.fact_chargeback WHERE received_date_key = -1 OR merchant_key = -1;
    EXEC test.usp_assert_zero @n, N'chargebacks with an Unknown received date or merchant';
END
GO

/* ---------------------------------------------------------------------
   Merchant history (type-2 dimension) is consistent:
     * exactly one current version per merchant
     * valid_from <= valid_to
     * versions follow on without gaps or overlaps
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_gold_merchant_history
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT, @examples NVARCHAR(2000);

    SELECT @n = COUNT(*), @examples = STRING_AGG(CONCAT(merchant_id, N' (', current_versions, N')'), N', ')
    FROM (SELECT merchant_id, SUM(CASE WHEN is_current = 1 THEN 1 ELSE 0 END) AS current_versions
          FROM gold.dim_merchant WHERE merchant_key <> -1
          GROUP BY merchant_id) m
    WHERE current_versions <> 1;
    EXEC test.usp_assert_zero @n, N'merchants without exactly one current version', @examples;

    SELECT @n = COUNT(*) FROM gold.dim_merchant WHERE valid_from > valid_to;
    EXEC test.usp_assert_zero @n, N'merchant versions with valid_from after valid_to';

    SELECT @n = COUNT(*), @examples = STRING_AGG(CAST(merchant_id AS NVARCHAR(50)), N', ')
    FROM (SELECT merchant_id, valid_from,
                 LAG(valid_to) OVER (PARTITION BY merchant_id ORDER BY valid_from) AS prev_valid_to
          FROM gold.dim_merchant WHERE merchant_key <> -1) v
    WHERE prev_valid_to IS NOT NULL AND valid_from <> DATEADD(DAY, 1, prev_valid_to);
    EXEC test.usp_assert_zero @n, N'merchant versions with a gap or overlap before them', @examples;
END
GO

/* ---------------------------------------------------------------------
   dim_date has every day between its first and last date.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_gold_dim_date_continuous
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @expected INT, @actual INT;

    SELECT @expected = DATEDIFF(DAY, MIN(full_date), MAX(full_date)) + 1, @actual = COUNT(DISTINCT full_date)
    FROM gold.dim_date WHERE date_key <> -1;

    EXEC test.usp_assert_equal @expected, @actual, N'days in dim_date between its first and last date';
END
GO

/* ---------------------------------------------------------------------
   gold.agg_chargeback_monitoring agrees with the facts it summarizes
   (rows it can place: known merchant, card network and date).
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_gold_monitoring_view_totals
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @view_cb BIGINT, @fact_cb BIGINT, @view_sales BIGINT, @fact_sales BIGINT;

    SELECT @view_cb = SUM(chargeback_count), @view_sales = SUM(sales_count) FROM gold.agg_chargeback_monitoring;

    SELECT @fact_cb = COUNT(*) FROM gold.fact_chargeback
    WHERE merchant_key <> -1 AND network IS NOT NULL AND received_date_key <> -1;

    SELECT @fact_sales = COUNT(*) FROM gold.fact_transaction
    WHERE is_revenue = 1 AND card_brand IS NOT NULL AND merchant_key <> -1 AND date_key <> -1;

    EXEC test.usp_assert_equal @fact_cb,    @view_cb,    N'chargebacks in agg_chargeback_monitoring vs fact_chargeback';
    EXEC test.usp_assert_equal @fact_sales, @view_sales, N'sales in agg_chargeback_monitoring vs fact_transaction';
END
GO
