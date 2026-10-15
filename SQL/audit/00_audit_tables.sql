/* =====================================================================
   Script    : 00_audit_tables.sql
   Purpose   : Tables that record changes made by hand to the database.
               Safe to re-run: tables are created only if missing, so the
               audit history is never lost.

   Tables
   ------
     audit.data_change_log    - one row per row inserted, updated or deleted
                                in a ref table (the business-rule tables
                                maintained by hand). Written by the triggers
                                in 01_audit_triggers.sql.
     audit.schema_change_log  - one row per CREATE / ALTER / DROP of a table,
                                view, procedure, function, trigger, index or
                                schema in the database.

   Load procedures are NOT audited here: every run already writes a row to
   audit.load_log (see SQL\silver\00_foundation.sql).
   ===================================================================== */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- required by the XML methods in audit.v_schema_change_log
SET ANSI_NULLS ON;
GO

IF SCHEMA_ID(N'audit') IS NULL EXEC (N'CREATE SCHEMA audit');
GO

/* ---------------------------------------------------------------------
   audit.data_change_log
   ---------------------------------------------------------------------
   key_values  : the row's primary key as JSON   {"network":"Visa","program_name":"Early Warning"}
   old_values  : the whole row before the change (NULL for an insert)
   new_values  : the whole row after the change  (NULL for a delete)
   An update that changes nothing (e.g. a re-run deploy MERGE) is not logged.
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'audit.data_change_log', N'U') IS NULL
    CREATE TABLE audit.data_change_log (
        change_id    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_audit_data_change_log PRIMARY KEY,
        changed_at   DATETIME2(3)   NOT NULL CONSTRAINT DF_audit_data_change_log_changed_at DEFAULT SYSUTCDATETIME(),  -- UTC
        changed_by   NVARCHAR(128)  NOT NULL CONSTRAINT DF_audit_data_change_log_changed_by DEFAULT ORIGINAL_LOGIN(),
        app_name     NVARCHAR(128)  NULL     CONSTRAINT DF_audit_data_change_log_app_name   DEFAULT APP_NAME(),        -- e.g. SSMS, SQLCMD
        host_name    NVARCHAR(128)  NULL     CONSTRAINT DF_audit_data_change_log_host_name  DEFAULT HOST_NAME(),
        table_name   SYSNAME        NOT NULL,      -- e.g. ref.chargeback_monitoring_program
        operation    VARCHAR(6)     NOT NULL,      -- INSERT / UPDATE / DELETE
        key_values   NVARCHAR(4000) NOT NULL,
        old_values   NVARCHAR(MAX)  NULL,
        new_values   NVARCHAR(MAX)  NULL
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_audit_data_change_log_table' AND object_id = OBJECT_ID(N'audit.data_change_log'))
    CREATE INDEX IX_audit_data_change_log_table ON audit.data_change_log (table_name, changed_at DESC);
GO

/* ---------------------------------------------------------------------
   audit.schema_change_log
   ---------------------------------------------------------------------
   The trigger stores SQL Server's event description (EVENTDATA) as XML
   without reading it, so the trigger can never fail a deploy because of
   session settings; audit.v_schema_change_log reads the fields out.
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'audit.schema_change_log', N'U') IS NULL
    CREATE TABLE audit.schema_change_log (
        change_id    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_audit_schema_change_log PRIMARY KEY,
        changed_at   DATETIME2(3)   NOT NULL CONSTRAINT DF_audit_schema_change_log_changed_at DEFAULT SYSUTCDATETIME(),  -- UTC
        changed_by   NVARCHAR(128)  NOT NULL CONSTRAINT DF_audit_schema_change_log_changed_by DEFAULT ORIGINAL_LOGIN(),
        app_name     NVARCHAR(128)  NULL     CONSTRAINT DF_audit_schema_change_log_app_name   DEFAULT APP_NAME(),
        host_name    NVARCHAR(128)  NULL     CONSTRAINT DF_audit_schema_change_log_host_name  DEFAULT HOST_NAME(),
        event_data   XML            NOT NULL
    );
GO

CREATE OR ALTER VIEW audit.v_schema_change_log
AS
SELECT
    l.change_id,
    l.changed_at,
    l.changed_by,
    l.app_name,
    l.host_name,
    l.event_data.value('(/EVENT_INSTANCE/EventType)[1]',  'NVARCHAR(100)') AS event_type,    -- e.g. ALTER_PROCEDURE
    l.event_data.value('(/EVENT_INSTANCE/ObjectType)[1]', 'NVARCHAR(100)') AS object_type,   -- e.g. PROCEDURE
    l.event_data.value('(/EVENT_INSTANCE/SchemaName)[1]', 'SYSNAME')       AS schema_name,
    l.event_data.value('(/EVENT_INSTANCE/ObjectName)[1]', 'SYSNAME')       AS object_name,
    l.event_data.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'NVARCHAR(MAX)') AS command_text
FROM audit.schema_change_log l;
GO
