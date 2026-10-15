# Change auditing – SegPay

SQL Server triggers record every change made **by hand** to the warehouse: who made it, when, from which application, and what changed. Together with `audit.load_log`, which records every load, this means no change to the database's rules, data or code goes unrecorded.

## Folder layout

| Path | What it is |
|---|---|
| `00_audit_tables.sql` | `audit.data_change_log`, `audit.schema_change_log` and the view `audit.v_schema_change_log`. Creates only missing tables, so the history is never lost. |
| `01_audit_triggers.sql` | The procedure that builds data-change triggers, a trigger for every `ref` table, and the database-level schema-change trigger. |
| `deploy_audit.sql` | Runs both files in order. |

## What is audited, and why

| What | Trigger | Logged to |
|---|---|---|
| Rows inserted, updated or deleted in any `ref` table | `ref.trg_<table>_audit`, one per table | `audit.data_change_log` |
| `CREATE`, `ALTER` or `DROP` of a table, view, procedure, function, trigger, index or schema | `trg_audit_schema_changes` (on the database) | `audit.schema_change_log` |

**The `ref` tables** hold the business rules people maintain by hand:

| Table | Holds | A change affects |
|---|---|---|
| `ref.country_alias` | Country spellings mapped to ISO codes | Country in every silver table |
| `ref.card_brand_alias` | Card brand and network spellings | Card brand and network everywhere |
| `ref.acquirer_alias` | Acquirer name spellings | Acquirer everywhere |
| `ref.test_merchant` | Test merchants | Which rows are excluded as test data |
| `ref.response_code_class` | Approved / soft decline / hard decline | Decline analysis in gold |
| `ref.chargeback_monitoring_program` | Card-network chargeback thresholds | Which merchants are flagged, **immediately** (the monitoring view reads it live) |

A change to any of these changes report numbers, so each one is recorded with the row before and after.

**The load tables (bronze, silver, gold) have no triggers, deliberately:**
- They're written only by the load procedures, and every run is already recorded in `audit.load_log`, with rows read, loaded and removed and why.
- Row triggers would add about 1.6 million audit rows per refresh and slow every load.
- Silver and gold are rebuilt with `TRUNCATE`, which doesn't fire triggers, so a trigger-based trail would be incomplete anyway.
- `gold.dim_merchant` keeps its own history of merchant changes.

## How the triggers work

**Data-change triggers** are generated, not written by hand. `audit.usp_create_change_trigger` reads a table's primary key and creates `ref.trg_<table>_audit`. `01_audit_triggers.sql` runs it for **every** table in the `ref` schema, so a new `ref` table is audited as soon as the script is re-run. A `ref` table without a primary key is reported and skipped.

For each statement, the trigger matches the rows before and after the change on the primary key:

| Before | After | Logged as |
|---|---|---|
| — | row | `INSERT` |
| row | — | `DELETE` |
| row | row, with a value changed | `UPDATE` |
| row | row, nothing changed | not logged (e.g. a deploy script re-running its MERGE) |

An update that changes the primary key itself is logged as a `DELETE` of the old key and an `INSERT` of the new one.

**The schema-change trigger** stores SQL Server's event description (`EVENTDATA()`) as XML and doesn't read it inside the trigger. Reading XML needs session settings that sqlcmd doesn't use by default, and a failing schema trigger would block every deploy. `audit.v_schema_change_log` reads the fields out instead. Temporary (`#`) tables live in `tempdb` and aren't logged.

## Columns

`audit.data_change_log`

| Column | Meaning |
|---|---|
| `changed_at` | When, in UTC |
| `changed_by` | The login that made the change |
| `app_name`, `host_name` | The application (e.g. SSMS, SQLCMD) and computer it came from |
| `table_name` | e.g. `ref.chargeback_monitoring_program` |
| `operation` | `INSERT`, `UPDATE` or `DELETE` |
| `key_values` | The row's primary key, as JSON |
| `old_values`, `new_values` | The whole row before and after, as JSON |

`audit.v_schema_change_log` has the same who / when / where columns, plus `event_type` (e.g. `ALTER_PROCEDURE`), `object_type`, `schema_name`, `object_name` and `command_text` (the full statement).

## Example queries

```sql
-- Who changed the chargeback thresholds, and what were they before?
SELECT changed_at, changed_by, operation, key_values, old_values, new_values
FROM audit.data_change_log
WHERE table_name = 'ref.chargeback_monitoring_program'
ORDER BY changed_at DESC;

-- One value before and after (JSON_VALUE reads a field from the JSON)
SELECT changed_at, changed_by,
       JSON_VALUE(old_values, '$.min_ratio') AS old_min_ratio,
       JSON_VALUE(new_values, '$.min_ratio') AS new_min_ratio
FROM audit.data_change_log
WHERE table_name = 'ref.chargeback_monitoring_program' AND operation = 'UPDATE';

-- What code changed in the last 7 days?
SELECT changed_at, changed_by, event_type, schema_name, object_name
FROM audit.v_schema_change_log
WHERE changed_at >= DATEADD(DAY, -7, SYSUTCDATETIME())
ORDER BY changed_at DESC;
```

## Deploying

From this folder, after the silver and gold layers:

```
sqlcmd -S "DESKTOP-G6OG89D\SQLEXPRESS10" -E -C -d SegPay -b -I -i deploy_audit.sql
```

`-I` turns on `QUOTED_IDENTIFIER`, which the view's XML functions need. Safe to re-run: tables are created only if missing, and triggers are replaced.

## Turning auditing off temporarily

For a large one-off reference-data change you'd rather not log row by row:

```sql
DISABLE TRIGGER ref.trg_country_alias_audit ON ref.country_alias;
-- ... change ...
ENABLE TRIGGER ref.trg_country_alias_audit ON ref.country_alias;
```

**Note:** disabling a trigger is **not** recorded anywhere (SQL Server raises no event for it that a trigger can catch), so changes made while it's off leave no trace. Re-enable it straight away.
