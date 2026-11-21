/* =====================================================================
   06 - Data quality checks and cleaning audit
   Project : Altitude Outfitters - SQL Server Data Warehouse & Analytics
   Engine  : Microsoft SQL Server 2017+ (T-SQL, written for SSMS 19/20)
   Part A: automated PASS/FAIL tests on the warehouse (expected value vs actual value)
   Part B: audit of what the cleaning step fixed (before/after evidence)
   ===================================================================== */
USE AltitudeOutfitters;
GO

/* ------------------------- PART A: automated tests ------------------------- */
SELECT area, check_name, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'Completeness' AS area, 'Customers: staging distinct ids = warehouse rows' AS check_name,
           CAST((SELECT COUNT(DISTINCT customer_id) FROM stg.dim_customers) AS BIGINT) AS expected,
           CAST((SELECT COUNT(*) FROM dw.dim_customer) AS BIGINT) AS actual
    UNION ALL SELECT 'Completeness', 'Orders: staging rows = warehouse rows',
           (SELECT COUNT(*) FROM stg.fact_orders), (SELECT COUNT(*) FROM dw.fact_orders)
    UNION ALL SELECT 'Completeness', 'Order lines: staging distinct line ids = warehouse rows',
           (SELECT COUNT(DISTINCT order_line_id) FROM stg.fact_order_lines), (SELECT COUNT(*) FROM dw.fact_order_lines)
    UNION ALL SELECT 'Completeness', 'Returns: staging rows = warehouse rows',
           (SELECT COUNT(*) FROM stg.fact_returns), (SELECT COUNT(*) FROM dw.fact_returns)
    UNION ALL SELECT 'Completeness', 'Marketing spend: staging rows = warehouse rows (no unmapped channel names)',
           (SELECT COUNT(*) FROM stg.fact_marketing_spend), (SELECT COUNT(*) FROM dw.fact_marketing_spend)
    UNION ALL SELECT 'Completeness', 'Sales view keeps every order line (no row lost in joins to fx / product / store)',
           (SELECT COUNT(*) FROM dw.fact_order_lines), (SELECT COUNT(*) FROM rpt.vw_sales_line)

    UNION ALL SELECT 'Date logic', 'Orders shipped before they were placed',            0,
           (SELECT COUNT(*) FROM dw.fact_orders WHERE ship_date < order_date)
    UNION ALL SELECT 'Date logic', 'Orders delivered before they were shipped',         0,
           (SELECT COUNT(*) FROM dw.fact_orders WHERE delivery_date < ship_date)
    UNION ALL SELECT 'Date logic', 'Completed orders without a delivery date',          0,
           (SELECT COUNT(*) FROM dw.fact_orders WHERE order_status = 'Completed' AND delivery_date IS NULL)
    UNION ALL SELECT 'Date logic', 'Orders outside the date dimension range',          0,
           (SELECT COUNT(*) FROM dw.fact_orders AS o WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date AS d WHERE d.date_value = o.order_date))
    UNION ALL SELECT 'Date logic', 'Returns dated before the order',                    0,
           (SELECT COUNT(*) FROM dw.fact_returns AS r JOIN dw.fact_order_lines AS l ON l.order_line_id = r.order_line_id
                                                       JOIN dw.fact_orders AS o ON o.order_id = l.order_id WHERE r.return_date < o.order_date)

    UNION ALL SELECT 'Business rules', 'Cancelled orders that still have a carrier',     0,
           (SELECT COUNT(*) FROM dw.fact_orders WHERE order_status = 'Cancelled' AND carrier IS NOT NULL)
    UNION ALL SELECT 'Business rules', 'Marketplace orders that carry a customer id (marketplace owns the customer)', 0,
           (SELECT COUNT(*) FROM dw.fact_orders AS o JOIN dw.dim_store AS s ON s.store_id = o.store_id WHERE s.channel = 'Marketplace' AND o.customer_id IS NOT NULL)
    UNION ALL SELECT 'Business rules', 'Owned-channel orders without a customer id',     0,
           (SELECT COUNT(*) FROM dw.fact_orders AS o JOIN dw.dim_store AS s ON s.store_id = o.store_id WHERE s.channel <> 'Marketplace' AND o.customer_id IS NULL)
    UNION ALL SELECT 'Business rules', 'Order currency differs from the currency of the ship-to country', 0,
           (SELECT COUNT(*) FROM dw.fact_orders AS o JOIN dw.dim_geography AS g ON g.country_code = o.ship_to_country WHERE o.currency_code <> g.currency_code)
    UNION ALL SELECT 'Business rules', 'Promotion applied outside its validity window', 0,
           (SELECT COUNT(*) FROM dw.fact_orders AS o JOIN dw.dim_promotion AS p ON p.promo_id = o.promo_id WHERE o.order_date < p.start_date OR o.order_date > p.end_date)
    UNION ALL SELECT 'Business rules', 'Returned quantity larger than the quantity sold', 0,
           (SELECT COUNT(*) FROM dw.fact_returns AS r JOIN dw.fact_order_lines AS l ON l.order_line_id = r.order_line_id WHERE r.return_qty > l.quantity)
    UNION ALL SELECT 'Business rules', 'Refund larger than the value of the returned units', 0,
           (SELECT COUNT(*) FROM dw.fact_returns AS r JOIN dw.fact_order_lines AS l ON l.order_line_id = r.order_line_id
             WHERE r.refund_amount_local > r.return_qty * l.unit_price_local * (1 - l.discount_pct) + 0.01)

    UNION ALL SELECT 'Domain', 'Non-positive unit prices',                 0, (SELECT COUNT(*) FROM dw.fact_order_lines WHERE unit_price_local <= 0)
    UNION ALL SELECT 'Domain', 'Selling below landed cost by more than 60% (data error candidates)', 0,
           (SELECT COUNT(*) FROM rpt.vw_sales_line WHERE net_revenue_usd < 0.4 * cogs_usd)
    UNION ALL SELECT 'Domain', 'CSAT outside 1-5',                         0, (SELECT COUNT(*) FROM dw.fact_support_tickets WHERE csat_score < 1 OR csat_score > 5)
    UNION ALL SELECT 'Domain', 'Resolution time shorter than first response', 0, (SELECT COUNT(*) FROM dw.fact_support_tickets WHERE resolution_hours < first_response_hours)
    UNION ALL SELECT 'Domain', 'Negative stock or stock-out days above 31',    0, (SELECT COUNT(*) FROM dw.fact_inventory_snapshot WHERE units_on_hand < 0 OR stockout_days > 31)
    UNION ALL SELECT 'Domain', 'Customers born before 1920 or after signup',   0,
           (SELECT COUNT(*) FROM dw.dim_customer WHERE birth_date < '1920-01-01' OR birth_date > signup_date)
) AS t
ORDER BY CASE WHEN expected = actual THEN 1 ELSE 0 END, area, check_name;     -- failures first
GO

/* ------------------------- PART B: cleaning audit (before -> after) ------------------------- */
SELECT issue, rows_affected, fix_applied
FROM (
    SELECT 1 AS sort_key, 'Duplicate customer rows' AS issue,
           (SELECT COUNT(*) - COUNT(DISTINCT customer_id) FROM stg.dim_customers) AS rows_affected,
           'ROW_NUMBER() de-duplication on customer_id' AS fix_applied
    UNION ALL SELECT 2, 'Duplicate order-line rows',
           (SELECT COUNT(*) - COUNT(DISTINCT order_line_id) FROM stg.fact_order_lines), 'ROW_NUMBER() de-duplication on order_line_id'
    UNION ALL SELECT 3, 'Order timestamps in legacy dd.MM.yyyy HH:mm format',
           (SELECT COUNT(*) FROM stg.fact_orders WHERE order_datetime LIKE '[0-9][0-9].[0-9][0-9].[0-9][0-9][0-9][0-9] %'),
           'Pattern test + DATETIME2FROMPARTS (no ambiguous dd/MM vs MM/dd guessing)'
    UNION ALL SELECT 4, 'Gender spelled in non-standard form (F, m, Woman, blank ...)',
           (SELECT COUNT(*) FROM (SELECT DISTINCT customer_id, gender FROM stg.dim_customers) AS x
             WHERE gender IS NULL OR gender COLLATE Latin1_General_CS_AS NOT IN ('Female', 'Male', 'Non-binary')),
           'CASE mapping on LOWER(TRIM()) to 3 standard values + Unknown'
    UNION ALL SELECT 5, 'City written in UPPER CASE or with stray spaces',
           (SELECT COUNT(*) FROM (SELECT DISTINCT customer_id, city FROM stg.dim_customers) AS x
             WHERE city COLLATE Latin1_General_CS_AS = UPPER(city) COLLATE Latin1_General_CS_AS OR city <> LTRIM(RTRIM(city))),
           'Canonical spelling look-up = most frequent properly-cased variant'
    UNION ALL SELECT 6, 'Placeholder birth dates (1900-01-01)',
           (SELECT COUNT(*) FROM (SELECT DISTINCT customer_id, birth_date FROM stg.dim_customers) AS x WHERE birth_date = '1900-01-01'), 'Converted to NULL'
    UNION ALL SELECT 7, 'Product category in lower case / subcategory with trailing space',
           (SELECT COUNT(*) FROM stg.dim_products WHERE category COLLATE Latin1_General_CS_AS = LOWER(category) COLLATE Latin1_General_CS_AS OR subcategory <> RTRIM(subcategory)),
           'Canonical category look-up + RTRIM'
    UNION ALL SELECT 8, 'Payment method spelled "Credit card"',
           (SELECT COUNT(*) FROM stg.fact_orders WHERE payment_method COLLATE Latin1_General_CS_AS = 'Credit card'), 'Standardised to "Credit Card"'
    UNION ALL SELECT 9, 'Marketing channel with a non-canonical name (Facebook Ads, meta ads, google ads)',
           (SELECT COUNT(*) FROM stg.fact_marketing_spend AS s JOIN dw.dim_marketing_channel AS c ON c.channel_name = LTRIM(RTRIM(s.channel))
             WHERE s.channel COLLATE Latin1_General_CS_AS <> c.channel_name COLLATE Latin1_General_CS_AS)
           + (SELECT COUNT(*) FROM stg.fact_marketing_spend WHERE LOWER(channel) = 'facebook ads'),
           'Alias table (dw.channel_alias) joined on LOWER(TRIM())'
    UNION ALL SELECT 10, 'Marketing rows with missing spend',
           (SELECT COUNT(*) FROM stg.fact_marketing_spend WHERE NULLIF(spend_usd, '') IS NULL), 'Kept as NULL and flagged (is_spend_missing = 1), not silently turned into 0'
    UNION ALL SELECT 11, 'Order lines with blank discount',
           (SELECT COUNT(*) FROM stg.fact_order_lines WHERE NULLIF(discount_pct, '') IS NULL), 'Treated as 0% discount'
) AS a
ORDER BY sort_key;
GO
