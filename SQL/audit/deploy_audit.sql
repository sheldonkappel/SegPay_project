/* =====================================================================
   Script    : deploy_audit.sql
   Purpose   : Deploys change auditing: the audit tables and the triggers
               that fill them.

   Safe to re-run: tables are created only if missing (audit history is
   never lost); triggers use CREATE OR ALTER. Re-run it after adding a
   table to the ref schema, so the new table is audited too.

   How to run (from the SQL\audit folder - :r paths are relative):
       sqlcmd -S "DESKTOP-G6OG89D\SQLEXPRESS10" -E -C -d SegPay -b -I -i deploy_audit.sql
   Requires the silver and gold layers (their foundation scripts create
   the ref tables).
   ===================================================================== */
:on error exit

PRINT N'1/2 Audit tables';
GO
:r 00_audit_tables.sql

PRINT N'2/2 Audit triggers';
GO
:r 01_audit_triggers.sql
