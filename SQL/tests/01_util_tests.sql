/* =====================================================================
   Script    : 01_util_tests.sql
   Purpose   : Tests for the shared cleaning functions in SQL\silver\00_foundation.sql.
               Every silver table depends on these, so each test lists the
               real-world inputs the function must handle and the answer
               expected for each. To cover a new format, add a row.
   ===================================================================== */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   util.fn_parse_date: every date format in the sources; ambiguous slash
   dates read US month/day first, day-first only when US is impossible.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_util_parse_date
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bad INT, @examples NVARCHAR(2000);

    SELECT @bad = COUNT(*),
           @examples = STRING_AGG(CONCAT(N'''', c.input, N''' -> ', ISNULL(CONVERT(CHAR(10), p.date_us_first, 23), N'NULL'),
                                         N' (expected ', ISNULL(CONVERT(CHAR(10), c.expected, 23), N'NULL'), N')'), N'; ')
    FROM (VALUES
        (N'2024-09-30',          CAST('2024-09-30' AS DATE)),   -- ISO
        (N'2024-09-30 13:45:00', '2024-09-30'),                 -- ISO with time
        (N'20240930',            '2024-09-30'),                 -- compact (gateway settle_date)
        (N'30-Sep-24',           '2024-09-30'),
        (N'30-Sep-2024',         '2024-09-30'),
        (N'30 Sep 2024',         '2024-09-30'),
        (N'Aug 24, 2026',        '2026-08-24'),                 -- billing created_at
        (N'30-09-2024',          '2024-09-30'),                 -- day-month-year with dashes
        (N'03/04/2025',          '2025-03-04'),                 -- ambiguous: US month/day first
        (N'10/31/2024',          '2024-10-31'),                 -- only valid as US
        (N'25/12/2024',          '2024-12-25'),                 -- only valid day-first
        (N'4/5/2026',            '2026-04-05'),                 -- single digits
        (N'  2024-09-30  ',      '2024-09-30'),                 -- surrounding spaces
        (N'2024-02-30',          NULL),                         -- impossible date
        (N'N/A',                 NULL),
        (N'NULL',                NULL),
        (N'-',                   NULL),
        (N'',                    NULL),
        (N'not a date',          NULL)
    ) c (input, expected)
    CROSS APPLY util.fn_parse_date(c.input) p
    WHERE NOT (p.date_us_first = c.expected OR (p.date_us_first IS NULL AND c.expected IS NULL));

    EXEC test.usp_assert_zero @bad, N'date inputs parsed wrongly', @examples;

    -- Both readings of an ambiguous slash date are available to procedures that resolve it against another date
    DECLARE @us DATE, @dm DATE, @expected_us DATE = '2025-03-04', @expected_dm DATE = '2025-04-03';
    SELECT @us = us_date, @dm = dm_date FROM util.fn_parse_date(N'03/04/2025');
    EXEC test.usp_assert_equal @expected_us, @us, N'us_date of 03/04/2025';
    EXEC test.usp_assert_equal @expected_dm, @dm, N'dm_date of 03/04/2025';
END
GO

/* ---------------------------------------------------------------------
   util.fn_parse_amount: '$', thousands commas, decimal commas, (x) negatives
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_util_parse_amount
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bad INT, @examples NVARCHAR(2000);

    SELECT @bad = COUNT(*),
           @examples = STRING_AGG(CONCAT(N'''', c.input, N''' -> ', ISNULL(CONVERT(NVARCHAR(30), p.amount), N'NULL'),
                                         N' (expected ', ISNULL(CONVERT(NVARCHAR(30), c.expected), N'NULL'), N')'), N'; ')
    FROM (VALUES
        (N'29.95',      CAST(29.95 AS DECIMAL(19,4))),
        (N'$79.95',     79.95),                -- currency symbol
        (N'1,671.14',   1671.14),              -- thousands separator
        (N'$1,671.14',  1671.14),
        (N'1,234',      1234),                 -- thousands separator, no decimals
        (N'9,00',       9.00),                 -- decimal comma
        (N'(67.95)',    -67.95),               -- accounting negative (chargeback feed)
        (N'-0.99',      -0.99),
        (N'$-0.00',     0),
        (N' 12 ',       12),
        (N'',           NULL),
        (N'abc',        NULL)
    ) c (input, expected)
    CROSS APPLY util.fn_parse_amount(c.input) p
    WHERE NOT (p.amount = c.expected OR (p.amount IS NULL AND c.expected IS NULL));

    EXEC test.usp_assert_zero @bad, N'amount inputs parsed wrongly', @examples;
END
GO

/* ---------------------------------------------------------------------
   util.fn_parse_flag: yes/no in every spelling the sources use
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_util_parse_flag
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bad INT, @examples NVARCHAR(2000);

    SELECT @bad = COUNT(*),
           @examples = STRING_AGG(CONCAT(N'''', c.input, N''' -> ', ISNULL(CONVERT(CHAR(1), p.flag), N'NULL')), N'; ')
    FROM (VALUES
        (N'TRUE', CAST(1 AS BIT)), (N'true', 1), (N'T', 1), (N'Y', 1), (N'yes', 1), (N'1', 1), (N' Y ', 1),
        (N'FALSE', 0), (N'false', 0), (N'F', 0), (N'N', 0), (N'no', 0), (N'0', 0),
        (N'', NULL), (N'maybe', NULL), (NULL, NULL)
    ) c (input, expected)
    CROSS APPLY util.fn_parse_flag(c.input) p
    WHERE NOT (p.flag = c.expected OR (p.flag IS NULL AND c.expected IS NULL));

    EXEC test.usp_assert_zero @bad, N'flag inputs read wrongly', @examples;
END
GO

/* ---------------------------------------------------------------------
   util.fn_clean_text: trims, and placeholders become NULL
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_util_clean_text
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bad INT, @examples NVARCHAR(2000);

    SELECT @bad = COUNT(*),
           @examples = STRING_AGG(CONCAT(N'''', c.input, N''' -> ', ISNULL(N'''' + p.txt + N'''', N'NULL')), N'; ')
    FROM (VALUES
        (N'  billing@example.com  ', N'billing@example.com'),
        (N'Nancy', N'Nancy'),                  -- a real value that starts like 'NA'
        (N'N/A', NULL), (N'n/a', NULL), (N'NA', NULL), (N'NULL', NULL), (N'None', NULL), (N'-', NULL), (N'', NULL), (N'   ', NULL)
    ) c (input, expected)
    CROSS APPLY util.fn_clean_text(c.input) p
    WHERE NOT (p.txt = c.expected OR (p.txt IS NULL AND c.expected IS NULL));

    EXEC test.usp_assert_zero @bad, N'text inputs cleaned wrongly', @examples;
END
GO
