/* =====================================================================
   00 - Create database and schemas
   Project : Altitude Outfitters - SQL Server Data Warehouse & Analytics
   Engine  : Microsoft SQL Server 2017+ (T-SQL, written for SSMS 19/20)
   Creates the database and three schemas: stg (raw landing), dw (clean star schema), rpt (reporting views).
   ===================================================================== */

USE master;
GO
IF DB_ID(N'AltitudeOutfitters') IS NULL
    CREATE DATABASE AltitudeOutfitters;
GO
USE AltitudeOutfitters;
GO
IF SCHEMA_ID(N'stg') IS NULL EXEC (N'CREATE SCHEMA stg AUTHORIZATION dbo;');   -- staging: raw text, 1:1 with CSV files
IF SCHEMA_ID(N'dw')  IS NULL EXEC (N'CREATE SCHEMA dw  AUTHORIZATION dbo;');   -- data warehouse: typed, cleaned, constrained
IF SCHEMA_ID(N'rpt') IS NULL EXEC (N'CREATE SCHEMA rpt AUTHORIZATION dbo;');   -- reporting layer: views and procedures for BI tools
GO
