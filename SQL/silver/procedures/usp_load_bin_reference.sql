/* =====================================================================
   Procedure : silver.usp_load_bin_reference
   Source    : bronze.bin_reference   (raw text)
   Target    : silver.bin_reference   (cleaned, one row per BIN)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A BIN (Bank Identification Number) is the first 6 digits of a card number.
   This table says which brand, card type, tier and issuing bank / country a
   BIN belongs to. silver.transactions.card_bin6 joins here.

   Transformations
   ---------------
     * bin            : trimmed.
     * card_brand     : one name per brand via ref.card_brand_alias
                        (VI -> Visa, MC -> Mastercard, AX -> American Express, ...).
     * card_type      : Credit / Debit / Prepaid (C / D / P mapped).
     * card_category  : Standard / Classic / Gold / Platinum / Business.
     * issuer_name    : trailing country suffix removed
                        ('Capital Credit Union DE' -> 'Capital Credit Union').
     * issuer_country : 2-letter ISO code via ref.country_alias.
     * last_updated   : any supported format (util.fn_parse_date).
     * Duplicates     : one row per BIN - latest last_updated, then newest bronze load.
     * Missing / unrecognized values : NULL.
     * Lineage        : bronze source columns, load_run_id, silver_loaded_at.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs (missing card_type / category /
                 country were 'N/A'); shared date, country and brand lookups;
                 audit logging.

   Usage
   -----
     EXEC silver.usp_load_bin_reference;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_bin_reference
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.bin_reference',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Loaded    INT,
            @Excluded  INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.bin_reference does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.bin_reference;

        BEGIN TRAN;

        TRUNCATE TABLE silver.bin_reference;

        WITH s AS (
            SELECT
                NULLIF(TRIM(b.bin), '')                             AS bin,
                cb.card_brand,

                CASE UPPER(TRIM(b.card_type))
                    WHEN 'CREDIT'  THEN 'Credit'  WHEN 'C' THEN 'Credit'
                    WHEN 'DEBIT'   THEN 'Debit'   WHEN 'D' THEN 'Debit'
                    WHEN 'PREPAID' THEN 'Prepaid' WHEN 'P' THEN 'Prepaid'
                END                                                 AS card_type,

                CASE UPPER(TRIM(b.card_category))
                    WHEN 'STANDARD' THEN 'Standard'
                    WHEN 'CLASSIC'  THEN 'Classic'
                    WHEN 'GOLD'     THEN 'Gold'
                    WHEN 'PLATINUM' THEN 'Platinum'
                    WHEN 'BUSINESS' THEN 'Business'
                END                                                 AS card_category,

                -- Remove the trailing ' XX' country code (names over 3 characters only)
                CASE WHEN LEN(TRIM(b.issuer_name)) > 3
                     THEN LEFT(TRIM(b.issuer_name), LEN(TRIM(b.issuer_name)) - 3) END AS issuer_name,

                COALESCE(ca.country_code,
                         CASE WHEN x.ctry LIKE '[A-Z][A-Z]' THEN x.ctry END) AS issuer_country,

                lu.date_us_first                                    AS last_updated,

                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                       AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.bin_reference b
            CROSS APPLY (SELECT ctry = UPPER(REPLACE(TRIM(b.issuer_country), '.', ''))) x
            CROSS APPLY util.fn_parse_date(b.last_updated) lu
            LEFT JOIN ref.country_alias    ca ON ca.alias = x.ctry
            LEFT JOIN ref.card_brand_alias cb ON cb.alias = UPPER(TRIM(b.card_brand))
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY bin ORDER BY last_updated DESC, bronze_ingested_at DESC) AS rn
            FROM s
            WHERE bin IS NOT NULL
        )
        INSERT silver.bin_reference (
            bin, card_brand, card_type, card_category, issuer_name, issuer_country, last_updated,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            bin, card_brand, card_type, card_category, issuer_name, issuer_country, last_updated,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows         = @Bronze,
               SilverRows         = @Loaded,
               DuplicatesDropped  = @Bronze - @Loaded,
               CardBrandNotMapped = (SELECT COUNT(*) FROM silver.bin_reference WHERE card_brand IS NULL),
               CountryNotMapped   = (SELECT COUNT(*) FROM silver.bin_reference WHERE issuer_country IS NULL)
        INTO #summary;

        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        SET @Excluded = 0;
        SET @Dropped  = @Bronze - @Loaded;

        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Succeeded', @rows_read = @Bronze, @rows_loaded = @Loaded,
             @rows_excluded = @Excluded, @rows_dropped = @Dropped, @metrics = @Metrics;

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
