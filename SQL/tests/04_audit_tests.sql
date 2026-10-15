/* =====================================================================
   Script    : 04_audit_tests.sql
   Purpose   : The change-audit triggers (SQL\audit) are in place and on.
   ===================================================================== */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   Every ref table has its enabled data-change trigger. A new ref table
   fails this test until SQL\audit\deploy_audit.sql is re-run.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_audit_ref_triggers
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT, @examples NVARCHAR(2000);

    SELECT @n = COUNT(*), @examples = STRING_AGG(N'ref.' + t.name, N', ')
    FROM sys.tables t
    WHERE t.schema_id = SCHEMA_ID(N'ref')
      AND NOT EXISTS (SELECT 1 FROM sys.triggers tr
                      WHERE tr.parent_id = t.object_id AND tr.name = N'trg_' + t.name + N'_audit' AND tr.is_disabled = 0);

    EXEC test.usp_assert_zero @n, N'ref tables without an enabled audit trigger', @examples;
END
GO

/* ---------------------------------------------------------------------
   The database-level schema-change trigger exists and is enabled.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_audit_schema_trigger
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT = (SELECT COUNT(*) FROM sys.triggers
                      WHERE parent_class = 0 AND name = N'trg_audit_schema_changes' AND is_disabled = 0);

    EXEC test.usp_assert_equal 1, @n, N'enabled trg_audit_schema_changes triggers';
END
GO

/* ---------------------------------------------------------------------
   A change to a ref table is actually logged, with before and after.
   (The runner rolls the test change back.)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_test_audit_change_is_logged
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @before BIGINT = (SELECT ISNULL(MAX(change_id), 0) FROM audit.data_change_log), @n INT;

    INSERT ref.test_merchant (merchant_id, legacy_merchant_id, description) VALUES ('MRC-AUDIT-TEST', NULL, N'test');
    UPDATE ref.test_merchant SET description = N'test changed' WHERE merchant_id = 'MRC-AUDIT-TEST';
    DELETE ref.test_merchant WHERE merchant_id = 'MRC-AUDIT-TEST';

    SELECT @n = COUNT(*) FROM audit.data_change_log
    WHERE change_id > @before AND table_name = N'ref.test_merchant'
      AND JSON_VALUE(key_values, '$.merchant_id') = 'MRC-AUDIT-TEST'
      AND (   (operation = 'INSERT' AND old_values IS NULL AND JSON_VALUE(new_values, '$.description') = 'test')
           OR (operation = 'UPDATE' AND JSON_VALUE(old_values, '$.description') = 'test'
                                    AND JSON_VALUE(new_values, '$.description') = 'test changed')
           OR (operation = 'DELETE' AND new_values IS NULL));

    EXEC test.usp_assert_equal 3, @n, N'logged changes (insert, update, delete) for a test row in ref.test_merchant';
END
GO
