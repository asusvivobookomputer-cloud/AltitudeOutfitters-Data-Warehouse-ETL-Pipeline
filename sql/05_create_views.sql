/* =====================================================================
   05 - Reporting layer (schema [rpt]): business-logic views for Power BI / ad-hoc SQL
   Project : Altitude Outfitters - SQL Server Data Warehouse & Analytics
   Engine  : Microsoft SQL Server 2017+ (T-SQL, written for SSMS 19/20)

   Business definitions (single source of truth, so every report shows the same number):
     net_revenue_usd      = quantity * unit_price_local * (1 - discount_pct) * rate_to_usd   (rate of the ORDER month)
     cogs_usd             = quantity * unit_cost_usd                                          (landed cost at time of sale)
     contribution_margin  = net revenue - COGS - marketplace commission - payment fees
                            + shipping fees charged - carrier cost - refunds (converted at the order-month rate)
     is_valid_sale        = 0 for cancelled orders  -> every KPI query must filter is_valid_sale = 1
   ===================================================================== */
USE AltitudeOutfitters;
GO

/* ---------------------------------------------------------------------
   1) one row per order line, fully enriched and converted to USD
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_sales_line
AS
SELECT
    l.order_line_id,
    l.order_id,
    o.order_date,
    DATEFROMPARTS(YEAR(o.order_date), MONTH(o.order_date), 1)              AS month_start,
    o.customer_id,
    o.store_id,
    s.channel,
    o.ship_to_country                                                       AS country_code,
    g.country_name,
    o.currency_code,
    o.promo_id,
    o.order_status,
    CASE WHEN o.order_status <> 'Cancelled' THEN 1 ELSE 0 END               AS is_valid_sale,
    l.product_id,
    p.category,
    p.subcategory,
    p.brand_type,
    p.supplier_id,
    l.quantity,
    l.unit_price_local,
    l.discount_pct,
    fx.rate_to_usd,
    CAST(l.quantity * l.unit_price_local * fx.rate_to_usd                         AS DECIMAL(18,2)) AS gross_revenue_usd,
    CAST(l.quantity * l.unit_price_local * l.discount_pct * fx.rate_to_usd        AS DECIMAL(18,2)) AS discount_usd,
    CAST(l.quantity * l.unit_price_local * (1 - l.discount_pct) * fx.rate_to_usd  AS DECIMAL(18,2)) AS net_revenue_usd,
    CAST(l.quantity * l.unit_cost_usd                                             AS DECIMAL(18,2)) AS cogs_usd,
    CAST(l.quantity * l.unit_price_local * (1 - l.discount_pct)                   AS DECIMAL(18,2)) AS net_revenue_local
FROM dw.fact_order_lines AS l
JOIN dw.fact_orders      AS o  ON o.order_id    = l.order_id
JOIN dw.dim_store        AS s  ON s.store_id    = o.store_id
JOIN dw.dim_geography    AS g  ON g.country_code = o.ship_to_country
JOIN dw.dim_product      AS p  ON p.product_id  = l.product_id
JOIN dw.fx_rate          AS fx ON fx.currency_code = o.currency_code
                              AND fx.month_start   = DATEFROMPARTS(YEAR(o.order_date), MONTH(o.order_date), 1);
GO

/* ---------------------------------------------------------------------
   2) one row per order with the complete unit economics (contribution margin)
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_order_economics
AS
WITH line_agg AS (
    SELECT order_id,
           SUM(quantity)           AS units,
           SUM(gross_revenue_usd)  AS gross_revenue_usd,
           SUM(discount_usd)       AS discount_usd,
           SUM(net_revenue_usd)    AS net_revenue_usd,
           SUM(cogs_usd)           AS cogs_usd
    FROM rpt.vw_sales_line
    GROUP BY order_id
),
refund_agg AS (
    SELECT l.order_id,
           SUM(r.refund_amount_local * fx.rate_to_usd) AS refund_usd,
           SUM(r.return_qty)                           AS returned_units
    FROM dw.fact_returns     AS r
    JOIN dw.fact_order_lines AS l  ON l.order_line_id = r.order_line_id
    JOIN dw.fact_orders      AS o  ON o.order_id      = l.order_id
    JOIN dw.fx_rate          AS fx ON fx.currency_code = o.currency_code
                                  AND fx.month_start   = DATEFROMPARTS(YEAR(o.order_date), MONTH(o.order_date), 1)
    GROUP BY l.order_id
),
base AS (
    SELECT
        o.order_id,
        o.order_date,
        DATEFROMPARTS(YEAR(o.order_date), MONTH(o.order_date), 1)                     AS month_start,
        o.customer_id,
        o.store_id,
        s.channel,
        o.ship_to_country                                                              AS country_code,
        o.currency_code,
        o.promo_id,
        o.carrier,
        o.order_status,
        CASE WHEN o.order_status <> 'Cancelled' THEN 1 ELSE 0 END                      AS is_valid_sale,
        la.units,
        la.gross_revenue_usd,
        la.discount_usd,
        la.net_revenue_usd,
        la.cogs_usd,
        CAST(la.net_revenue_usd * s.marketplace_commission_pct AS DECIMAL(18,2))       AS commission_usd,
        CAST(la.net_revenue_usd * s.payment_fee_pct            AS DECIMAL(18,2))       AS payment_fee_usd,
        CAST(o.shipping_fee_local * fx.rate_to_usd             AS DECIMAL(18,2))       AS shipping_income_usd,
        o.shipping_cost_usd,
        CAST(COALESCE(ra.refund_usd, 0)                        AS DECIMAL(18,2))       AS refund_usd,
        COALESCE(ra.returned_units, 0)                                                 AS returned_units
    FROM dw.fact_orders AS o
    JOIN line_agg       AS la ON la.order_id = o.order_id
    JOIN dw.dim_store   AS s  ON s.store_id  = o.store_id
    JOIN dw.fx_rate     AS fx ON fx.currency_code = o.currency_code
                             AND fx.month_start   = DATEFROMPARTS(YEAR(o.order_date), MONTH(o.order_date), 1)
    LEFT JOIN refund_agg AS ra ON ra.order_id = o.order_id
)
SELECT
    base.*,
    CAST(base.net_revenue_usd - base.cogs_usd - base.commission_usd - base.payment_fee_usd
         + base.shipping_income_usd - base.shipping_cost_usd - base.refund_usd AS DECIMAL(18,2)) AS contribution_margin_usd
FROM base;
GO

/* ---------------------------------------------------------------------
   3) customer order history: order sequence number and cohort (first purchase month)
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_customer_order
AS
WITH seq AS (
    SELECT
        oe.customer_id,
        oe.order_id,
        oe.order_date,
        oe.month_start,
        oe.channel,
        oe.country_code,
        oe.net_revenue_usd,
        ROW_NUMBER() OVER (PARTITION BY oe.customer_id ORDER BY oe.order_date, oe.order_id) AS order_seq,
        MIN(oe.order_date) OVER (PARTITION BY oe.customer_id)                               AS first_order_date
    FROM rpt.vw_order_economics AS oe
    WHERE oe.customer_id IS NOT NULL
      AND oe.is_valid_sale = 1
)
SELECT
    seq.*,
    DATEFROMPARTS(YEAR(seq.first_order_date), MONTH(seq.first_order_date), 1) AS cohort_month
FROM seq;
GO

/* ---------------------------------------------------------------------
   4) marketing efficiency inputs: spend + platform claims + real new customers per month/country/channel
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_marketing_monthly
AS
WITH spend AS (
    SELECT DATEFROMPARTS(YEAR(spend_date), MONTH(spend_date), 1) AS month_start,
           country_code, channel_name,
           SUM(COALESCE(spend_usd, 0))                  AS spend_usd,
           SUM(CAST(is_spend_missing AS INT))           AS missing_spend_days,
           SUM(platform_conversions)                    AS platform_conversions,
           SUM(platform_revenue_usd)                    AS platform_revenue_usd
    FROM dw.fact_marketing_spend
    GROUP BY DATEFROMPARTS(YEAR(spend_date), MONTH(spend_date), 1), country_code, channel_name
),
newc AS (
    SELECT DATEFROMPARTS(YEAR(signup_date), MONTH(signup_date), 1) AS month_start,
           country_code, acquisition_channel AS channel_name,
           COUNT(*) AS new_customers
    FROM dw.dim_customer
    GROUP BY DATEFROMPARTS(YEAR(signup_date), MONTH(signup_date), 1), country_code, acquisition_channel
)
SELECT s.month_start, s.country_code, s.channel_name, s.spend_usd, s.missing_spend_days,
       s.platform_conversions, s.platform_revenue_usd, COALESCE(n.new_customers, 0) AS new_customers
FROM spend AS s
LEFT JOIN newc AS n ON n.month_start = s.month_start AND n.country_code = s.country_code AND n.channel_name = s.channel_name;
GO
