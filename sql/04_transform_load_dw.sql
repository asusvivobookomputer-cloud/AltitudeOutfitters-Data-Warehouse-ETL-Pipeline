/* =====================================================================
   04 - Clean, type and load the star schema  (stg -> dw)
   Project : Altitude Outfitters - SQL Server Data Warehouse & Analytics
   Engine  : Microsoft SQL Server 2017+ (T-SQL, written for SSMS 19/20)

   Data-quality problems handled here (see docs for before/after counts):
     1. Duplicate rows            : customers, order lines          -> ROW_NUMBER() de-duplication
     2. Mixed date formats        : ISO and dd.MM.yyyy in orders    -> pattern-tested parsing, no guessing
     3. Inconsistent labels       : gender, city case, category case, payment method, marketing channel
                                    -> CASE rules, canonical look-up (most frequent proper-cased spelling) and an alias table
     4. Placeholder values        : birth_date = 1900-01-01         -> NULL
     5. Blanks that mean "none"   : discount_pct blank -> 0; customer_id blank (marketplace) -> NULL; spend blank -> NULL + flag
     6. Business-rule fixes       : cancelled orders cannot have a carrier
   The whole load runs in ONE transaction: it either succeeds completely or rolls back.
   ===================================================================== */
USE AltitudeOutfitters;
GO

CREATE OR ALTER PROCEDURE dw.usp_load_dw
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---------- 0. empty the warehouse (children first) ---------- */
        DELETE FROM dw.fact_web_sessions;      DELETE FROM dw.fact_marketing_budget;  DELETE FROM dw.fact_marketing_spend;
        DELETE FROM dw.fact_targets;           DELETE FROM dw.fact_inventory_snapshot; DELETE FROM dw.fact_support_tickets;
        DELETE FROM dw.fact_returns;           DELETE FROM dw.fact_order_lines;       DELETE FROM dw.fact_orders;
        DELETE FROM dw.fx_rate;                DELETE FROM dw.dim_date;               DELETE FROM dw.dim_customer;
        DELETE FROM dw.dim_product;            DELETE FROM dw.dim_promotion;          DELETE FROM dw.dim_store;
        DELETE FROM dw.dim_warehouse;          DELETE FROM dw.dim_supplier;           DELETE FROM dw.channel_alias;
        DELETE FROM dw.dim_marketing_channel;  DELETE FROM dw.dim_geography;

        /* ---------- 1. small dimensions ---------- */
        INSERT INTO dw.dim_geography (country_code, country_name, region, currency_code, latitude, longitude)
        SELECT LTRIM(RTRIM(country_code)), country_name, region, currency_code,
               TRY_CAST(latitude AS DECIMAL(9,6)), TRY_CAST(longitude AS DECIMAL(9,6))
        FROM stg.dim_geography;

        INSERT INTO dw.dim_supplier (supplier_id, supplier_name, country, lead_time_days, quality_rating, payment_terms_days)
        SELECT supplier_id, supplier_name, country, TRY_CAST(lead_time_days AS INT),
               TRY_CAST(quality_rating AS DECIMAL(3,1)), TRY_CAST(payment_terms_days AS INT)
        FROM stg.dim_suppliers;

        INSERT INTO dw.dim_warehouse (warehouse_id, warehouse_name, city, country_code, open_date)
        SELECT warehouse_id, warehouse_name, city, country_code, TRY_CONVERT(DATE, open_date, 23)
        FROM stg.dim_warehouses;

        INSERT INTO dw.dim_store (store_id, store_name, channel, country_code, city, open_date, marketplace_commission_pct, payment_fee_pct)
        SELECT store_id, store_name, channel, country_code, city, TRY_CONVERT(DATE, open_date, 23),
               TRY_CAST(marketplace_commission_pct AS DECIMAL(5,4)), TRY_CAST(payment_fee_pct AS DECIMAL(5,4))
        FROM stg.dim_stores;

        INSERT INTO dw.dim_promotion (promo_id, promo_name, promo_type, start_date, end_date, discount_pct, channel_scope, country_scope, category_scope)
        SELECT promo_id, promo_name, promo_type, TRY_CONVERT(DATE, start_date, 23), TRY_CONVERT(DATE, end_date, 23),
               TRY_CAST(discount_pct AS DECIMAL(5,2)), channel_scope, country_scope, category_scope
        FROM stg.dim_promotions;

        INSERT INTO dw.dim_marketing_channel (channel_name, channel_group, is_paid)
        SELECT channel_name, channel_group, TRY_CAST(is_paid AS BIT)
        FROM stg.dim_marketing_channels;

        /* alias table: every canonical name in lower case + known wrong spellings seen in the source */
        INSERT INTO dw.channel_alias (alias_name, channel_name)
        SELECT LOWER(channel_name), channel_name FROM dw.dim_marketing_channel;
        INSERT INTO dw.channel_alias (alias_name, channel_name) VALUES (N'facebook ads', N'Meta Ads');

        /* ---------- 2. fx ---------- */
        INSERT INTO dw.fx_rate (month_start, currency_code, rate_to_usd)
        SELECT TRY_CONVERT(DATE, month_start, 23), currency_code, TRY_CAST(rate_to_usd AS DECIMAL(12,6))
        FROM stg.fx_rates;

        /* ---------- 3. date dimension (generated, not loaded) ---------- */
        ;WITH d AS (
            SELECT CAST('2023-01-01' AS DATE) AS dt
            UNION ALL
            SELECT DATEADD(DAY, 1, dt) FROM d WHERE dt < '2026-12-31'
        )
        INSERT INTO dw.dim_date (date_key, date_value, [year], [quarter], month_number, month_name, month_start, iso_weekday, day_name, is_weekend)
        SELECT YEAR(dt) * 10000 + MONTH(dt) * 100 + DAY(dt), dt, YEAR(dt), DATEPART(QUARTER, dt), MONTH(dt), DATENAME(MONTH, dt),
               DATEFROMPARTS(YEAR(dt), MONTH(dt), 1),
               (DATEDIFF(DAY, '1900-01-01', dt) % 7) + 1,                       -- 1900-01-01 was a Monday => ISO weekday, independent of DATEFIRST
               DATENAME(WEEKDAY, dt),
               CASE WHEN (DATEDIFF(DAY, '1900-01-01', dt) % 7) + 1 >= 6 THEN 1 ELSE 0 END
        FROM d
        OPTION (MAXRECURSION 0);

        /* ---------- 4. products: canonical category spelling + trimmed subcategory ---------- */
        ;WITH cat_counts AS (
            SELECT LTRIM(RTRIM(category)) AS cat_clean, COUNT(*) AS cnt
            FROM stg.dim_products
            WHERE LTRIM(RTRIM(category)) COLLATE Latin1_General_CS_AS <> LOWER(LTRIM(RTRIM(category))) COLLATE Latin1_General_CS_AS  -- ignore all-lower-case variants
            GROUP BY LTRIM(RTRIM(category))
        ), cat_canon AS (
            SELECT UPPER(cat_clean) AS cat_key, cat_clean,
                   ROW_NUMBER() OVER (PARTITION BY UPPER(cat_clean) ORDER BY cnt DESC) AS rn
            FROM cat_counts
        )
        INSERT INTO dw.dim_product (product_id, sku, product_name, category, subcategory, brand, brand_type, supplier_id,
                                    list_price_usd, standard_cost_usd, launch_date, discontinued_date, weight_kg)
        SELECT p.product_id, p.sku, p.product_name,
               COALESCE(cc.cat_clean, LTRIM(RTRIM(p.category))),
               LTRIM(RTRIM(p.subcategory)), p.brand, p.brand_type, p.supplier_id,
               TRY_CAST(p.list_price_usd AS DECIMAL(10,2)), TRY_CAST(p.standard_cost_usd AS DECIMAL(10,2)),
               TRY_CONVERT(DATE, p.launch_date, 23), TRY_CONVERT(DATE, NULLIF(p.discontinued_date, ''), 23),
               TRY_CAST(p.weight_kg AS DECIMAL(6,2))
        FROM stg.dim_products AS p
        LEFT JOIN cat_canon AS cc ON cc.cat_key = UPPER(LTRIM(RTRIM(p.category))) AND cc.rn = 1;

        /* ---------- 5. customers: de-duplicate, standardise, null-out placeholders ---------- */
        ;WITH city_counts AS (
            SELECT LTRIM(RTRIM(city)) AS city_clean, COUNT(*) AS cnt
            FROM stg.dim_customers
            WHERE city IS NOT NULL
              AND LTRIM(RTRIM(city)) COLLATE Latin1_General_CS_AS <> UPPER(LTRIM(RTRIM(city))) COLLATE Latin1_General_CS_AS  -- ignore ALL-CAPS variants
            GROUP BY LTRIM(RTRIM(city))
        ), city_canon AS (
            SELECT UPPER(city_clean) AS city_key, city_clean,
                   ROW_NUMBER() OVER (PARTITION BY UPPER(city_clean) ORDER BY cnt DESC) AS rn
            FROM city_counts
        ), cust AS (
            SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.customer_id ORDER BY (SELECT NULL)) AS dup_rn
            FROM stg.dim_customers AS s
        )
        INSERT INTO dw.dim_customer (customer_id, signup_date, customer_type, country_code, city, gender, birth_date, acquisition_channel, email_opt_in)
        SELECT c.customer_id,
               TRY_CONVERT(DATE, c.signup_date, 23),
               c.customer_type,
               c.country_code,
               cc.city_clean,
               CASE WHEN LOWER(LTRIM(RTRIM(c.gender))) IN ('female', 'f', 'woman') THEN 'Female'
                    WHEN LOWER(LTRIM(RTRIM(c.gender))) IN ('male', 'm', 'man')     THEN 'Male'
                    WHEN LOWER(LTRIM(RTRIM(c.gender))) = 'non-binary'               THEN 'Non-binary'
                    ELSE 'Unknown' END,
               CASE WHEN b.bd >= '1920-01-01' THEN b.bd END,                          -- 1900-01-01 placeholder -> NULL
               a.channel_name,
               TRY_CAST(c.email_opt_in AS BIT)
        FROM cust AS c
        CROSS APPLY (SELECT TRY_CONVERT(DATE, NULLIF(c.birth_date, ''), 23) AS bd) AS b
        LEFT JOIN city_canon AS cc ON cc.city_key = UPPER(LTRIM(RTRIM(c.city))) AND cc.rn = 1
        JOIN dw.channel_alias AS a ON a.alias_name = LTRIM(RTRIM(c.acquisition_channel))
        WHERE c.dup_rn = 1;

        /* ---------- 6. orders: two date formats, blanks to NULL, label fixes ---------- */
        INSERT INTO dw.fact_orders (order_id, order_datetime, order_date, customer_id, store_id, ship_to_country, promo_id, currency_code,
                                    payment_method, order_status, fulfilment_type, carrier, ship_date, promised_delivery_date, delivery_date,
                                    shipping_fee_local, shipping_cost_usd)
        SELECT o.order_id, x.order_datetime, CAST(x.order_datetime AS DATE),
               NULLIF(LTRIM(RTRIM(o.customer_id)), ''), o.store_id, o.ship_to_country, NULLIF(LTRIM(RTRIM(o.promo_id)), ''), o.currency_code,
               CASE WHEN LOWER(LTRIM(RTRIM(o.payment_method))) = 'credit card' THEN N'Credit Card' ELSE LTRIM(RTRIM(o.payment_method)) END,
               o.order_status, o.fulfilment_type,
               CASE WHEN o.order_status = 'Cancelled' THEN NULL ELSE NULLIF(LTRIM(RTRIM(o.carrier)), '') END,     -- business rule: no carrier on cancelled orders
               TRY_CONVERT(DATE, NULLIF(o.ship_date, ''), 23),
               TRY_CONVERT(DATE, NULLIF(o.promised_delivery_date, ''), 23),
               TRY_CONVERT(DATE, NULLIF(o.delivery_date, ''), 23),
               COALESCE(TRY_CAST(o.shipping_fee_local AS DECIMAL(12,2)), 0),
               COALESCE(TRY_CAST(o.shipping_cost_usd AS DECIMAL(12,2)), 0)
        FROM stg.fact_orders AS o
        CROSS APPLY (
            SELECT CASE
                     WHEN o.order_datetime LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]'      -- 2024-03-05 14:20:11
                          THEN TRY_CONVERT(DATETIME2(0), o.order_datetime, 120)
                     WHEN o.order_datetime LIKE '[0-9][0-9].[0-9][0-9].[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]'                 -- 05.03.2024 14:20  (legacy POS)
                          THEN DATETIME2FROMPARTS(CAST(SUBSTRING(o.order_datetime, 7, 4)  AS INT), CAST(SUBSTRING(o.order_datetime, 4, 2)  AS INT),
                                                  CAST(LEFT(o.order_datetime, 2)          AS INT), CAST(SUBSTRING(o.order_datetime, 12, 2) AS INT),
                                                  CAST(SUBSTRING(o.order_datetime, 15, 2) AS INT), 0, 0, 0)
                   END AS order_datetime
        ) AS x;

        /* ---------- 7. order lines: remove duplicate keys, blank discount = 0 ---------- */
        ;WITH l AS (
            SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.order_line_id ORDER BY (SELECT NULL)) AS dup_rn
            FROM stg.fact_order_lines AS s
        )
        INSERT INTO dw.fact_order_lines (order_line_id, order_id, product_id, quantity, unit_price_local, discount_pct, unit_cost_usd)
        SELECT order_line_id, order_id, product_id, TRY_CAST(quantity AS INT), TRY_CAST(unit_price_local AS DECIMAL(12,2)),
               COALESCE(TRY_CAST(discount_pct AS DECIMAL(5,2)), 0), TRY_CAST(unit_cost_usd AS DECIMAL(12,2))
        FROM l
        WHERE dup_rn = 1;

        /* ---------- 8. other facts ---------- */
        INSERT INTO dw.fact_returns (return_id, order_line_id, return_date, return_qty, return_reason, item_condition, refund_amount_local, refund_status)
        SELECT return_id, order_line_id, TRY_CONVERT(DATE, return_date, 23), TRY_CAST(return_qty AS INT), return_reason, item_condition,
               TRY_CAST(refund_amount_local AS DECIMAL(12,2)), refund_status
        FROM stg.fact_returns;

        INSERT INTO dw.fact_support_tickets (ticket_id, order_id, created_at, ticket_category, priority, contact_channel,
                                             first_response_hours, resolution_hours, csat_score)
        SELECT ticket_id, order_id, TRY_CONVERT(DATETIME2(0), created_at, 120), ticket_category, priority, contact_channel,
               TRY_CAST(first_response_hours AS DECIMAL(8,1)), TRY_CAST(resolution_hours AS DECIMAL(8,1)),
               TRY_CAST(NULLIF(csat_score, '') AS DECIMAL(2,1))
        FROM stg.fact_support_tickets;

        INSERT INTO dw.fact_inventory_snapshot (snapshot_date, product_id, warehouse_id, units_on_hand, units_on_order, stockout_days, unit_cost_usd)
        SELECT TRY_CONVERT(DATE, snapshot_date, 23), product_id, warehouse_id, TRY_CAST(units_on_hand AS INT), TRY_CAST(units_on_order AS INT),
               TRY_CAST(stockout_days AS INT), TRY_CAST(unit_cost_usd AS DECIMAL(10,2))
        FROM stg.fact_inventory_snapshot;

        INSERT INTO dw.fact_marketing_spend (spend_date, country_code, channel_name, spend_usd, is_spend_missing, impressions, clicks,
                                             platform_conversions, platform_revenue_usd)
        SELECT TRY_CONVERT(DATE, s.[date], 23), s.country_code, a.channel_name,
               TRY_CAST(NULLIF(s.spend_usd, '') AS DECIMAL(12,2)),
               CASE WHEN NULLIF(s.spend_usd, '') IS NULL THEN 1 ELSE 0 END,
               TRY_CAST(s.impressions AS BIGINT), TRY_CAST(s.clicks AS BIGINT), TRY_CAST(s.platform_conversions AS INT),
               TRY_CAST(s.platform_revenue_usd AS DECIMAL(14,2))
        FROM stg.fact_marketing_spend AS s
        JOIN dw.channel_alias AS a ON a.alias_name = LTRIM(RTRIM(s.channel));

        INSERT INTO dw.fact_web_sessions (week_start_date, country_code, device_category, traffic_source, sessions, users, bounced_sessions,
                                          product_view_sessions, add_to_cart_sessions, checkout_sessions, orders, total_session_seconds)
        SELECT TRY_CONVERT(DATE, week_start_date, 23), country_code, device_category, traffic_source, TRY_CAST(sessions AS INT), TRY_CAST(users AS INT),
               TRY_CAST(bounced_sessions AS INT), TRY_CAST(product_view_sessions AS INT), TRY_CAST(add_to_cart_sessions AS INT),
               TRY_CAST(checkout_sessions AS INT), TRY_CAST(orders AS INT), TRY_CAST(total_session_seconds AS BIGINT)
        FROM stg.fact_web_sessions;

        INSERT INTO dw.fact_targets (month_start, country_code, category, target_net_revenue_usd, target_gross_margin_pct)
        SELECT TRY_CONVERT(DATE, month_start, 23), country_code, category, TRY_CAST(target_net_revenue_usd AS DECIMAL(14,2)),
               TRY_CAST(target_gross_margin_pct AS DECIMAL(5,3))
        FROM stg.fact_targets;

        INSERT INTO dw.fact_marketing_budget (month_start, country_code, channel_name, budget_usd)
        SELECT TRY_CONVERT(DATE, b.month_start, 23), b.country_code, a.channel_name, TRY_CAST(b.budget_usd AS DECIMAL(12,2))
        FROM stg.fact_marketing_budget AS b
        JOIN dw.channel_alias AS a ON a.alias_name = LTRIM(RTRIM(b.channel));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;      -- re-raise the original error to the caller
    END CATCH;
END;
GO

EXEC dw.usp_load_dw;
GO

/* Control report: staging rows vs warehouse rows (differences = removed duplicates) */
SELECT 'customers'   AS entity, (SELECT COUNT(*) FROM stg.dim_customers)     AS staging_rows, (SELECT COUNT(*) FROM dw.dim_customer)     AS dw_rows
UNION ALL SELECT 'orders',        (SELECT COUNT(*) FROM stg.fact_orders),          (SELECT COUNT(*) FROM dw.fact_orders)
UNION ALL SELECT 'order_lines',   (SELECT COUNT(*) FROM stg.fact_order_lines),     (SELECT COUNT(*) FROM dw.fact_order_lines)
UNION ALL SELECT 'returns',       (SELECT COUNT(*) FROM stg.fact_returns),         (SELECT COUNT(*) FROM dw.fact_returns)
UNION ALL SELECT 'marketing',     (SELECT COUNT(*) FROM stg.fact_marketing_spend), (SELECT COUNT(*) FROM dw.fact_marketing_spend)
UNION ALL SELECT 'inventory',     (SELECT COUNT(*) FROM stg.fact_inventory_snapshot), (SELECT COUNT(*) FROM dw.fact_inventory_snapshot);
GO
