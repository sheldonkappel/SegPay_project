/* =====================================================================
   Procedure : gold.usp_load_dim_date
   Target    : gold.dim_date   (one row per calendar day + Unknown)
   Load type : Adds any missing days in the range; existing rows untouched.

   Purpose
   -------
   The calendar every gold fact joins to (date_key = YYYYMMDD), so reports
   can group by month, quarter, week or weekday and show days with no
   activity.

   Parameters
   ----------
     @start_date, @end_date : range to cover (default 2017-01-01 to
                              2030-12-31 - silver's earliest date is 2018,
                              next rebill dates run into 2027).

   Columns
   -------
     date_key -1 = Unknown (facts with no date). day_of_week follows ISO:
     1 = Monday ... 7 = Sunday, independent of the server's DATEFIRST.

   Usage
   -----
     EXEC gold.usp_load_dim_date;
   ===================================================================== */
CREATE OR ALTER PROCEDURE gold.usp_load_dim_date
    @run_id     UNIQUEIDENTIFIER = NULL,
    @start_date DATE = '2017-01-01',
    @end_date   DATE = '2030-12-31'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'gold.dim_date',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Inserted  INT,
            @Total     INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'gold.dim_date does not exist - run SQL\gold\01_gold_tables.sql first.', 1;

        BEGIN TRAN;

        -- Unknown member
        IF NOT EXISTS (SELECT 1 FROM gold.dim_date WHERE date_key = -1)
            INSERT gold.dim_date (date_key, quarter_name, month_name, month_short, year_month, day_name)
            VALUES (-1, 'Unknown', 'Unknown', 'Unk', 'Unknown', 'Unknown');

        INSERT gold.dim_date (
            date_key, full_date, year, quarter, quarter_name, month, month_name, month_short, year_month,
            month_start_date, month_end_date, iso_week, day_of_month, day_of_week, day_name, is_weekend, is_month_end)
        SELECT
            YEAR(d.dt) * 10000 + MONTH(d.dt) * 100 + DAY(d.dt),
            d.dt,
            YEAR(d.dt),
            DATEPART(QUARTER, d.dt),
            CONCAT(YEAR(d.dt), ' Q', DATEPART(QUARTER, d.dt)),
            MONTH(d.dt),
            DATENAME(MONTH, d.dt),
            LEFT(DATENAME(MONTH, d.dt), 3),
            CONVERT(CHAR(7), d.dt, 23),
            DATEFROMPARTS(YEAR(d.dt), MONTH(d.dt), 1),
            EOMONTH(d.dt),
            DATEPART(ISO_WEEK, d.dt),
            DAY(d.dt),
            w.iso_dow,
            DATENAME(WEEKDAY, d.dt),
            CASE WHEN w.iso_dow >= 6 THEN 1 ELSE 0 END,
            CASE WHEN d.dt = EOMONTH(d.dt) THEN 1 ELSE 0 END
        FROM (SELECT DATEADD(DAY, g.value, @start_date) AS dt
              FROM GENERATE_SERIES(0, DATEDIFF(DAY, @start_date, @end_date)) g) d
        -- ISO weekday: 1900-01-01 was a Monday
        CROSS APPLY (SELECT iso_dow = DATEDIFF(DAY, '19000101', d.dt) % 7 + 1) w
        WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date x WHERE x.full_date = d.dt);

        SET @Inserted = @@ROWCOUNT;

        COMMIT;

        SELECT DaysAdded = @Inserted,
               TotalRows = (SELECT COUNT(*) FROM gold.dim_date),
               FirstDate = (SELECT MIN(full_date) FROM gold.dim_date),
               LastDate  = (SELECT MAX(full_date) FROM gold.dim_date)
        INTO #summary;

        SELECT @Total = TotalRows FROM #summary;
        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Succeeded', @rows_loaded = @Total, @metrics = @Metrics;

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
