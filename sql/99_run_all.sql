/* =====================================================================
   99 - Run everything in order (SQLCMD mode)
   In SSMS: Query menu -> "SQLCMD Mode" must be ON.  Edit the two variables below, then press F5.
   Alternatively open and execute scripts 00 -> 08 one by one.
   ===================================================================== */


USE AltitudeOutfitters;
GO

-- 1. Automatically drops ALL Foreign Keys in the DW schema to permanently fix the dependency ordering issue.
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql += N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id))
    + '.' + QUOTENAME(OBJECT_NAME(parent_object_id)) 
    + ' DROP CONSTRAINT ' + QUOTENAME(name) + ';' + CHAR(13)
FROM sys.foreign_keys
WHERE schema_id = SCHEMA_ID('dw');

EXEC sp_executesql @sql;
GO

-- 2. Now we can drop all tables with ease
DROP TABLE IF EXISTS dw.fact_support_tickets;
DROP TABLE IF EXISTS dw.fact_returns;
DROP TABLE IF EXISTS dw.fact_order_lines;
DROP TABLE IF EXISTS dw.fact_orders;
DROP TABLE IF EXISTS dw.fact_inventory_snapshot;
DROP TABLE IF EXISTS dw.fact_marketing_spend;
DROP TABLE IF EXISTS dw.fact_marketing_budget;
DROP TABLE IF EXISTS dw.fact_web_sessions;
DROP TABLE IF EXISTS dw.fact_targets;
DROP TABLE IF EXISTS dw.fx_rates;

DROP TABLE IF EXISTS dw.dim_customer;
DROP TABLE IF EXISTS dw.dim_product;
DROP TABLE IF EXISTS dw.dim_store;
DROP TABLE IF EXISTS dw.dim_warehouse;
DROP TABLE IF EXISTS dw.dim_supplier;
DROP TABLE IF EXISTS dw.dim_promotion;
DROP TABLE IF EXISTS dw.dim_marketing_channel;
DROP TABLE IF EXISTS dw.dim_geography;
DROP TABLE IF EXISTS dw.dim_date;
GO






:setvar ScriptPath "C:\Users\Gsm\Desktop\SQL\sql\"
:r $(ScriptPath)00_create_database.sql
:r $(ScriptPath)01_create_staging_tables.sql
:r $(ScriptPath)02_load_staging.sql
:r $(ScriptPath)03_create_dw_tables.sql
:r $(ScriptPath)04_transform_load_dw.sql
:r $(ScriptPath)05_create_views.sql
:r $(ScriptPath)06_data_quality_checks.sql
:r $(ScriptPath)08_procedures_and_functions.sql
/* 07_analytics_queries.sql is meant to be read and run query by query. */




