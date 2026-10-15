/* =====================================================================
   Migration : 2026-10-15_01_ingested_at_utc.sql
   Purpose   : Make bronze load times consistent (all UTC) and give every
               bronze default constraint a standard name.

   Why
   ---
   bronze.txn_pre_migration and bronze.txn_post_migration filled
   ingested_at with SYSDATETIME() - local server time (US Eastern) - while
   the other 19 bronze tables use SYSUTCDATETIME(). The two sets of load
   times were 4-5 hours apart, and silver carried the mix through as
   bronze_ingested_at.

   What it does (all in one transaction)
   -------------------------------------
     1. Converts the existing ingested_at values in the two transaction
        tables from US Eastern to UTC. AT TIME ZONE applies the right
        offset for each timestamp (EST -5 / EDT -4).
        Runs only while the old SYSDATETIME() default is still in place,
        so running this script twice never shifts the times twice.
     2. Replaces the two defaults with SYSUTCDATETIME().
     3. Renames every bronze default constraint to DF_bronze_<table>_<column>
        so the database matches SQL\bronze\01_bronze_tables.sql.

   Safe to re-run. After running it, rebuild silver so bronze_ingested_at
   picks up the UTC times:  EXEC silver.usp_load_all;
   ===================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRAN;

DECLARE @tbl SYSNAME, @df SYSNAME, @def NVARCHAR(4000), @sql NVARCHAR(MAX), @rows INT;

/* ---------------------------------------------------------------------
   1 + 2. Transaction tables: convert existing times, switch default to UTC
   --------------------------------------------------------------------- */
DECLARE txn CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name, dc.name, dc.definition
    FROM sys.tables t
    JOIN sys.default_constraints dc ON dc.parent_object_id = t.object_id
                                   AND COL_NAME(dc.parent_object_id, dc.parent_column_id) = 'ingested_at'
    WHERE t.schema_id = SCHEMA_ID('bronze') AND t.name IN ('txn_pre_migration', 'txn_post_migration');
OPEN txn;
FETCH NEXT FROM txn INTO @tbl, @df, @def;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF LOWER(@def) LIKE '%sysdatetime()%' AND LOWER(@def) NOT LIKE '%sysutcdatetime()%'
    BEGIN
        -- Local (US Eastern) -> UTC
        SET @sql = N'UPDATE bronze.' + QUOTENAME(@tbl) + N'
                     SET ingested_at = CAST((ingested_at AT TIME ZONE ''Eastern Standard Time'') AT TIME ZONE ''UTC'' AS DATETIME2(3));';
        EXEC sys.sp_executesql @sql;
        SET @rows = @@ROWCOUNT;

        SET @sql = N'ALTER TABLE bronze.' + QUOTENAME(@tbl) + N' DROP CONSTRAINT ' + QUOTENAME(@df) + N';
                     ALTER TABLE bronze.' + QUOTENAME(@tbl) + N' ADD CONSTRAINT ' + QUOTENAME(@df) + N' DEFAULT (SYSUTCDATETIME()) FOR ingested_at;';
        EXEC sys.sp_executesql @sql;

        PRINT CONCAT(N'bronze.', @tbl, N': ', @rows, N' ingested_at values converted to UTC; default is now SYSUTCDATETIME().');
    END
    ELSE
        PRINT CONCAT(N'bronze.', @tbl, N': already UTC - skipped.');

    FETCH NEXT FROM txn INTO @tbl, @df, @def;
END
CLOSE txn; DEALLOCATE txn;

/* ---------------------------------------------------------------------
   3. Standard names for every bronze default constraint
   --------------------------------------------------------------------- */
DECLARE @col SYSNAME, @new SYSNAME;
DECLARE dfs CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name, COL_NAME(dc.parent_object_id, dc.parent_column_id), dc.name
    FROM sys.default_constraints dc
    JOIN sys.tables t ON t.object_id = dc.parent_object_id
    WHERE t.schema_id = SCHEMA_ID('bronze');
OPEN dfs;
FETCH NEXT FROM dfs INTO @tbl, @col, @df;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @new = N'DF_bronze_' + @tbl + N'_' + @col;
    IF @df <> @new
    BEGIN
        SET @sql = N'bronze.' + QUOTENAME(@df);
        EXEC sys.sp_rename @objname = @sql, @newname = @new, @objtype = N'OBJECT';
    END
    FETCH NEXT FROM dfs INTO @tbl, @col, @df;
END
CLOSE dfs; DEALLOCATE dfs;

COMMIT;

-- Result
SELECT OBJECT_NAME(parent_object_id) AS table_name, COL_NAME(parent_object_id, parent_column_id) AS column_name,
       name AS constraint_name, definition
FROM sys.default_constraints
WHERE OBJECT_SCHEMA_NAME(parent_object_id) = 'bronze'
ORDER BY 1, 2;
