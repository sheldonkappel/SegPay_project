/* =====================================================================
   Script    : 02_silver_tests.sql  (also holds the bronze test)
   Purpose   : Tests on the silver layer's data and load logs.
               Generic tests read the table list from the database, so a
               new silver table is covered automatically.
   ===================================================================== */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   Every bronze row is accounted for: for each procedure's latest
   successful load, rows read = rows loaded + test rows excluded +
   duplicates / superseded rows dropped. Nothing disappears silently.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_silver_load_counts_balance
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bad INT, @examples NVARCHAR(2000);

    WITH latest AS (
        SELECT l.*, ROW_NUMBER() OVER (PARTITION BY l.proc_name ORDER BY l.log_id DESC) AS rn
        FROM audit.load_log l
        WHERE l.proc_name LIKE N'silver.usp[_]load[_]%' AND l.proc_name <> N'silver.usp_load_all'
          AND l.status = 'Succeeded'
    )
    SELECT @bad = COUNT(*),
           @examples = STRING_AGG(CONCAT(proc_name, N': read ', rows_read, N' <> loaded ', rows_loaded,
                                         N' + excluded ', ISNULL(rows_excluded, 0), N' + dropped ', ISNULL(rows_dropped, 0)), N'; ')
    FROM latest
    WHERE rn = 1
      AND rows_read <> rows_loaded + ISNULL(rows_excluded, 0) + ISNULL(rows_dropped, 0);

    EXEC test.usp_assert_zero @bad, N'silver loads whose row counts do not add up', @examples;
END
GO

/* ---------------------------------------------------------------------
   Each silver table holds exactly the rows its latest load reported.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_silver_row_counts_match_log
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX), @bad INT, @examples NVARCHAR(2000);

    CREATE TABLE #check (target_table SYSNAME, logged INT, actual INT);

    WITH latest AS (
        SELECT l.target_table, l.rows_loaded, ROW_NUMBER() OVER (PARTITION BY l.proc_name ORDER BY l.log_id DESC) AS rn
        FROM audit.load_log l
        WHERE l.proc_name LIKE N'silver.usp[_]load[_]%' AND l.proc_name <> N'silver.usp_load_all'
          AND l.status = 'Succeeded' AND OBJECT_ID(l.target_table, N'U') IS NOT NULL
    )
    SELECT @sql = STRING_AGG(CAST(N'INSERT #check SELECT N''' + target_table + N''', ' + CAST(rows_loaded AS NVARCHAR(20))
                                  + N', COUNT(*) FROM ' + target_table + N';' AS NVARCHAR(MAX)), NCHAR(10))
    FROM latest WHERE rn = 1;

    EXEC sys.sp_executesql @sql;

    SELECT @bad = COUNT(*),
           @examples = STRING_AGG(CONCAT(target_table, N': log says ', logged, N', table has ', actual), N'; ')
    FROM #check WHERE logged <> actual;

    EXEC test.usp_assert_zero @bad, N'silver tables whose row count differs from their load log', @examples;
END
GO

/* ---------------------------------------------------------------------
   No test merchant appears in any silver table with a merchant_id.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_silver_no_test_merchants
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX), @bad INT, @examples NVARCHAR(2000);

    CREATE TABLE #found (table_name SYSNAME, n INT);

    SELECT @sql = STRING_AGG(CAST(N'INSERT #found SELECT N''silver.' + t.name + N''', COUNT(*) FROM silver.' + QUOTENAME(t.name)
                                  + N' WHERE merchant_id IN (SELECT merchant_id FROM ref.test_merchant);' AS NVARCHAR(MAX)), NCHAR(10))
    FROM sys.tables t
    JOIN sys.columns c ON c.object_id = t.object_id AND c.name = N'merchant_id'
    WHERE t.schema_id = SCHEMA_ID(N'silver');

    EXEC sys.sp_executesql @sql;

    SELECT @bad = SUM(n), @examples = STRING_AGG(CONCAT(table_name, N': ', n), N'; ')
    FROM #found WHERE n > 0;

    EXEC test.usp_assert_zero @bad, N'rows belonging to test merchants', @examples;
END
GO

/* ---------------------------------------------------------------------
   Transaction amounts carry the right sign: refunds, voids and
   chargebacks negative; sales, rebills and auths not negative.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_silver_transaction_signs
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @wrong_negative INT, @wrong_positive INT;

    SELECT @wrong_negative = SUM(CASE WHEN txn_type IN ('Sale', 'Rebill', 'Auth', 'Zero Auth') AND amount < 0 THEN 1 ELSE 0 END),
           @wrong_positive = SUM(CASE WHEN txn_type IN ('Refund', 'Void', 'Chargeback') AND amount > 0 THEN 1 ELSE 0 END)
    FROM silver.transactions;

    EXEC test.usp_assert_zero @wrong_negative, N'sales / rebills / auths with a negative amount';
    EXEC test.usp_assert_zero @wrong_positive, N'refunds / voids / chargebacks with a positive amount';
END
GO

/* ---------------------------------------------------------------------
   USD values are consistent: a USD amount converts to itself, and a
   conversion never flips the sign.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_silver_usd_amounts
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT;

    SELECT @n = COUNT(*) FROM silver.transactions WHERE currency = 'USD' AND amount_usd <> amount;
    EXEC test.usp_assert_zero @n, N'USD transactions whose amount_usd differs from amount';

    SELECT @n = COUNT(*) FROM silver.transactions WHERE SIGN(amount_usd) <> SIGN(amount);
    EXEC test.usp_assert_zero @n, N'transactions whose USD conversion changed the sign';

    SELECT @n = COUNT(*) FROM silver.chargebacks_acquirer_feed WHERE dispute_ccy = 'USD' AND dispute_amount_usd <> dispute_amount;
    EXEC test.usp_assert_zero @n, N'USD chargebacks whose dispute_amount_usd differs from dispute_amount';
END
GO

/* ---------------------------------------------------------------------
   Missing values are NULL, never placeholder text: no text column in
   silver holds 'N/A', 'NULL', 'NONE', '-' or an empty string.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_silver_no_placeholder_text
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX), @bad INT, @examples NVARCHAR(2000);

    CREATE TABLE #found (table_name SYSNAME, column_name SYSNAME, n INT);

    SELECT @sql = STRING_AGG(CAST(N'INSERT #found SELECT N''silver.' + t.name + N''', N''' + c.name + N''', COUNT(*) FROM silver.'
                                  + QUOTENAME(t.name) + N' WHERE UPPER(TRIM(' + QUOTENAME(c.name)
                                  + N')) IN (N'''', N''N/A'', N''NULL'', N''NONE'', N''-'');' AS NVARCHAR(MAX)), NCHAR(10))
    FROM sys.tables t
    JOIN sys.columns c ON c.object_id = t.object_id
    JOIN sys.types ty  ON ty.user_type_id = c.user_type_id
    WHERE t.schema_id = SCHEMA_ID(N'silver')
      AND ty.name IN (N'varchar', N'nvarchar', N'char', N'nchar')
      AND c.name NOT IN (N'source_system', N'source_file_name', N'ingested_by');   -- lineage, copied as received

    EXEC sys.sp_executesql @sql;

    SELECT @bad = SUM(n), @examples = STRING_AGG(CONCAT(table_name, N'.', column_name, N': ', n), N'; ')
    FROM #found WHERE n > 0;

    EXEC test.usp_assert_zero @bad, N'placeholder values (N/A, NULL, NONE, -, empty) in silver text columns', @examples;
END
GO

/* ---------------------------------------------------------------------
   (bronze) Every procedure or function that uses XML methods was created
   with QUOTED_IDENTIFIER ON. Without it the XML clearing-file load fails
   with "SET options have incorrect settings" - which happened once when
   the bronze procedures were redeployed with sqlcmd's default (OFF).
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_bronze_xml_settings
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT, @examples NVARCHAR(2000);

    SELECT @n = COUNT(*), @examples = STRING_AGG(OBJECT_SCHEMA_NAME(m.object_id) + N'.' + OBJECT_NAME(m.object_id), N', ')
    FROM sys.sql_modules m
    WHERE m.uses_quoted_identifier = 0
      AND (m.definition LIKE N'%.value(%' OR m.definition LIKE N'%.nodes(%' OR m.definition LIKE N'%.query(%');

    EXEC test.usp_assert_zero @n, N'modules using XML methods created with QUOTED_IDENTIFIER OFF', @examples;
END
GO
