/* =====================================================================
   02 - Bulk load CSV files into staging
   Project : Altitude Outfitters - SQL Server Data Warehouse & Analytics
   Engine  : Microsoft SQL Server 2017+ (T-SQL, written for SSMS 19/20)
   Edit @DataPath below. SQL Server service account must have read access to that folder.
   ===================================================================== */

USE AltitudeOutfitters;
GO
SET NOCOUNT ON;

DECLARE @DataPath NVARCHAR(400) = N'C:\Users\Gsm\Desktop\SQL\data\';   -- <<< CHANGE THIS (must end with a backslash)

DECLARE @files TABLE (id INT IDENTITY(1,1) PRIMARY KEY, table_name SYSNAME, file_name NVARCHAR(100));
INSERT INTO @files (table_name, file_name)
VALUES
    (N'dim_customers', N'dim_customers.csv'),
    (N'dim_geography', N'dim_geography.csv'),
    (N'dim_marketing_channels', N'dim_marketing_channels.csv'),
    (N'dim_products', N'dim_products.csv'),
    (N'dim_promotions', N'dim_promotions.csv'),
    (N'dim_stores', N'dim_stores.csv'),
    (N'dim_suppliers', N'dim_suppliers.csv'),
    (N'dim_warehouses', N'dim_warehouses.csv'),
    (N'fact_inventory_snapshot', N'fact_inventory_snapshot.csv'),
    (N'fact_marketing_budget', N'fact_marketing_budget.csv'),
    (N'fact_marketing_spend', N'fact_marketing_spend.csv'),
    (N'fact_order_lines', N'fact_order_lines.csv'),
    (N'fact_orders', N'fact_orders.csv'),
    (N'fact_returns', N'fact_returns.csv'),
    (N'fact_support_tickets', N'fact_support_tickets.csv'),
    (N'fact_targets', N'fact_targets.csv'),
    (N'fact_web_sessions', N'fact_web_sessions.csv'),
    (N'fx_rates', N'fx_rates.csv');

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @files);
DECLARE @tbl SYSNAME, @file NVARCHAR(100), @sql NVARCHAR(MAX);

WHILE @i <= @n
BEGIN
    SELECT @tbl = table_name, @file = file_name FROM @files WHERE id = @i;

    SET @sql = N'TRUNCATE TABLE stg.<tbl>;
                 BULK INSERT stg.<tbl>
                 FROM ''<path>''
                 WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','',
                       ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'', KEEPNULLS, TABLOCK);';
    SET @sql = REPLACE(REPLACE(@sql, N'<tbl>', QUOTENAME(@tbl)), N'<path>', @DataPath + @file);
    PRINT CONCAT(N'Loading ', @file, N' ...');
    EXEC sys.sp_executesql @sql;

    SET @i += 1;
END;

/* Row-count control report: compare with the numbers in the README */
SELECT t.name AS staging_table, SUM(p.row_count) AS row_count
FROM sys.dm_db_partition_stats AS p
JOIN sys.tables  AS t ON t.object_id = p.object_id
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE s.name = N'stg' AND p.index_id IN (0, 1)
GROUP BY t.name
ORDER BY t.name;
GO

/* TROUBLESHOOTING
   - "Cannot bulk load because the file could not be opened"  -> wrong path or no permission for the SQL Server service account.
   - Row terminator errors -> change ROWTERMINATOR to '\r\n' if you re-saved the CSV files on Windows.
   - FORMAT = 'CSV' needs SQL Server 2017+. On older versions remove FORMAT and use FIELDQUOTE = '"' only if needed.
*/
