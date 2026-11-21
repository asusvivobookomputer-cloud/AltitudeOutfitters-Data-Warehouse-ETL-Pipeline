/* =====================================================================
   07 - Analytical queries (17 business questions)
   Project : Altitude Outfitters - SQL Server Data Warehouse & Analytics
   Engine  : Microsoft SQL Server 2017+ (T-SQL, written for SSMS 19/20)
   Each query answers one business question. Every KPI query filters is_valid_sale = 1 (cancelled orders excluded).
   Techniques: CTEs, window functions (LAG, ROW_NUMBER, NTILE, running totals, moving windows), conditional aggregation,
               gaps-and-islands, constant-currency analysis, cohort analysis, RFM scoring, Pareto/ABC classification.
   ===================================================================== */
USE AltitudeOutfitters;
GO

/* ---------------------------------------------------------------------
   Q01  How is revenue trending? Month-over-month, year-over-year and year-to-date.
   Techniques: CTE, LAG(1) and LAG(12), running total with a partitioned window, NULLIF for safe division
   --------------------------------------------------------------------- */
WITH monthly AS (
    SELECT month_start, SUM(net_revenue_usd) AS net_revenue_usd
    FROM rpt.vw_sales_line
    WHERE is_valid_sale = 1
    GROUP BY month_start
)
SELECT month_start,
       net_revenue_usd,
       CAST(100.0 * (net_revenue_usd / NULLIF(LAG(net_revenue_usd, 1)  OVER (ORDER BY month_start), 0) - 1) AS DECIMAL(7,1)) AS mom_growth_pct,
       CAST(100.0 * (net_revenue_usd / NULLIF(LAG(net_revenue_usd, 12) OVER (ORDER BY month_start), 0) - 1) AS DECIMAL(7,1)) AS yoy_growth_pct,
       SUM(net_revenue_usd) OVER (PARTITION BY YEAR(month_start) ORDER BY month_start ROWS UNBOUNDED PRECEDING)               AS ytd_revenue_usd
FROM monthly
ORDER BY month_start;
GO

/* ---------------------------------------------------------------------
   Q02  Which sales channel really makes money? Gross margin vs contribution margin.
   Techniques: aggregation over the order-economics view, ratio KPIs
   Insight to look for: marketplace looks healthy on gross margin but loses ~27 points after commission, shipping and refunds.
   --------------------------------------------------------------------- */
SELECT channel,
       CAST(SUM(net_revenue_usd) AS DECIMAL(18,0))                                                          AS net_revenue_usd,
       CAST(100.0 * (1 - SUM(cogs_usd) / SUM(net_revenue_usd)) AS DECIMAL(5,1))                              AS gross_margin_pct,
       CAST(SUM(commission_usd) AS DECIMAL(18,0))                                                           AS marketplace_commission_usd,
       CAST(SUM(shipping_cost_usd) - SUM(shipping_income_usd) AS DECIMAL(18,0))                             AS net_shipping_cost_usd,
       CAST(SUM(refund_usd) AS DECIMAL(18,0))                                                               AS refunds_usd,
       CAST(SUM(contribution_margin_usd) AS DECIMAL(18,0))                                                  AS contribution_margin_usd,
       CAST(100.0 * SUM(contribution_margin_usd) / SUM(net_revenue_usd) AS DECIMAL(5,1))                     AS contribution_margin_pct
FROM rpt.vw_order_economics
WHERE is_valid_sale = 1
GROUP BY channel
ORDER BY contribution_margin_pct DESC;
GO

/* ---------------------------------------------------------------------
   Q03  What are the top 3 products in every category, and how concentrated is each category?
   Techniques: ROW_NUMBER() OVER (PARTITION BY ...), SUM() OVER () for share of total
   --------------------------------------------------------------------- */
WITH product_revenue AS (
    SELECT category, product_id, SUM(net_revenue_usd) AS revenue_usd
    FROM rpt.vw_sales_line
    WHERE is_valid_sale = 1
    GROUP BY category, product_id
),
ranked AS (
    SELECT pr.category, pr.product_id, p.product_name, pr.revenue_usd,
           ROW_NUMBER() OVER (PARTITION BY pr.category ORDER BY pr.revenue_usd DESC)          AS rank_in_category,
           100.0 * pr.revenue_usd / SUM(pr.revenue_usd) OVER (PARTITION BY pr.category)      AS share_of_category_pct
    FROM product_revenue AS pr
    JOIN dw.dim_product  AS p ON p.product_id = pr.product_id
)
SELECT category, rank_in_category, product_name,
       CAST(revenue_usd AS DECIMAL(18,0))             AS revenue_usd,
       CAST(share_of_category_pct AS DECIMAL(5,1))    AS share_of_category_pct
FROM ranked
WHERE rank_in_category <= 3
ORDER BY category, rank_in_category;
GO

/* ---------------------------------------------------------------------
   Q04  Pareto / ABC classification: how many products generate 80% of revenue?
   Techniques: cumulative window sum, CASE classification using the share BEFORE the current product
   --------------------------------------------------------------------- */
WITH product_revenue AS (
    SELECT product_id, SUM(net_revenue_usd) AS revenue_usd
    FROM rpt.vw_sales_line
    WHERE is_valid_sale = 1
    GROUP BY product_id
),
cumulative AS (
    SELECT product_id, revenue_usd,
           SUM(revenue_usd) OVER (ORDER BY revenue_usd DESC ROWS UNBOUNDED PRECEDING) / SUM(revenue_usd) OVER () AS cum_share,
           revenue_usd / SUM(revenue_usd) OVER ()                                                              AS own_share
    FROM product_revenue
),
classified AS (
    SELECT *, CASE WHEN cum_share - own_share < 0.80 THEN 'A'
                   WHEN cum_share - own_share < 0.95 THEN 'B'
                   ELSE 'C' END AS abc_class
    FROM cumulative
)
SELECT abc_class,
       COUNT(*)                                                      AS products,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct_of_products,
       CAST(SUM(revenue_usd) AS DECIMAL(18,0))                       AS revenue_usd,
       CAST(100.0 * SUM(own_share) AS DECIMAL(5,1))                  AS pct_of_revenue
FROM classified
GROUP BY abc_class
ORDER BY abc_class;
GO

/* ---------------------------------------------------------------------
   Q05  Cohort retention: of the customers acquired in a month, what % buy again 1, 3, 6 and 12 months later?
   Techniques: ROW_NUMBER-based first-order flag (view), DATEDIFF on month starts, conditional aggregation (manual pivot),
               right-censoring (cohorts too young for a column show NULL instead of a misleading 0)
   --------------------------------------------------------------------- */
WITH cohort AS (
    SELECT customer_id, cohort_month FROM rpt.vw_customer_order WHERE order_seq = 1
),
activity AS (
    SELECT DISTINCT customer_id, DATEDIFF(MONTH, cohort_month, month_start) AS months_since_first
    FROM rpt.vw_customer_order
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS customers FROM cohort GROUP BY cohort_month
),
as_of AS (
    SELECT MAX(month_start) AS last_month FROM rpt.vw_customer_order
)
SELECT cs.cohort_month,
       cs.customers,
       CAST(100.0 * SUM(CASE WHEN a.months_since_first = 1  THEN 1 ELSE 0 END) / cs.customers AS DECIMAL(5,1)) AS buy_again_m1_pct,
       CAST(100.0 * SUM(CASE WHEN a.months_since_first = 3  THEN 1 ELSE 0 END) / cs.customers AS DECIMAL(5,1)) AS buy_again_m3_pct,
       CAST(100.0 * SUM(CASE WHEN a.months_since_first = 6  THEN 1 ELSE 0 END) / cs.customers AS DECIMAL(5,1)) AS buy_again_m6_pct,
       CASE WHEN DATEADD(MONTH, 12, cs.cohort_month) <= (SELECT last_month FROM as_of)
            THEN CAST(100.0 * SUM(CASE WHEN a.months_since_first = 12 THEN 1 ELSE 0 END) / cs.customers AS DECIMAL(5,1)) END AS buy_again_m12_pct
FROM cohort_size AS cs
JOIN cohort      AS c ON c.cohort_month = cs.cohort_month
JOIN activity    AS a ON a.customer_id  = c.customer_id
GROUP BY cs.cohort_month, cs.customers
ORDER BY cs.cohort_month;
GO

/* ---------------------------------------------------------------------
   Q06  RFM segmentation: who are the Champions and who is At Risk?
   Techniques: NTILE(5) scoring for recency and monetary value, threshold scoring for frequency (NTILE would split ties
               arbitrarily because >50% of customers have exactly one order), CASE rule engine, segment summary
   --------------------------------------------------------------------- */
WITH as_of AS (
    SELECT MAX(order_date) AS as_of_date FROM rpt.vw_customer_order
),
base AS (
    SELECT customer_id,
           DATEDIFF(DAY, MAX(order_date), (SELECT as_of_date FROM as_of)) AS recency_days,
           COUNT(*)                                                        AS frequency,
           SUM(net_revenue_usd)                                            AS monetary_usd
    FROM rpt.vw_customer_order
    GROUP BY customer_id
),
scored AS (
    SELECT *,
           NTILE(5) OVER (ORDER BY recency_days DESC)   AS r_score,      -- 5 = most recent
           CASE WHEN frequency >= 5 THEN 5 WHEN frequency = 4 THEN 4 WHEN frequency = 3 THEN 3 WHEN frequency = 2 THEN 2 ELSE 1 END AS f_score,
           NTILE(5) OVER (ORDER BY monetary_usd ASC)    AS m_score
    FROM base
),
segmented AS (
    SELECT *,
           CASE WHEN r_score >= 4 AND f_score >= 4 THEN '1 Champions'
                WHEN r_score >= 3 AND f_score >= 3 THEN '2 Loyal'
                WHEN r_score >= 4 AND f_score <= 2 THEN '3 New / Promising'
                WHEN r_score <= 2 AND f_score >= 3 THEN '4 At Risk (high value)'
                WHEN r_score <= 2 AND f_score <= 2 THEN '6 Hibernating'
                ELSE '5 Needs Attention' END AS segment
    FROM scored
)
SELECT segment,
       COUNT(*)                                                                          AS customers,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))                    AS pct_of_customers,
       CAST(SUM(monetary_usd) AS DECIMAL(18,0))                                          AS revenue_usd,
       CAST(100.0 * SUM(monetary_usd) / SUM(SUM(monetary_usd)) OVER () AS DECIMAL(5,1))  AS pct_of_revenue,
       CAST(AVG(CAST(recency_days AS FLOAT)) AS DECIMAL(7,0))                            AS avg_recency_days,
       CAST(AVG(CAST(frequency    AS FLOAT)) AS DECIMAL(5,2))                            AS avg_orders
FROM segmented
GROUP BY segment
ORDER BY segment;
GO

/* ---------------------------------------------------------------------
   Q07  Customer concentration: what share of revenue comes from the top 10% of customers?
   Techniques: NTILE(10), nested aggregate inside a window (SUM(SUM())) for share and cumulative share
   --------------------------------------------------------------------- */
WITH customer_revenue AS (
    SELECT customer_id, SUM(net_revenue_usd) AS revenue_usd
    FROM rpt.vw_customer_order
    GROUP BY customer_id
),
deciles AS (
    SELECT customer_id, revenue_usd, NTILE(10) OVER (ORDER BY revenue_usd DESC) AS decile
    FROM customer_revenue
)
SELECT decile,
       COUNT(*)                                                                                       AS customers,
       CAST(SUM(revenue_usd) AS DECIMAL(18,0))                                                        AS revenue_usd,
       CAST(100.0 * SUM(revenue_usd) / SUM(SUM(revenue_usd)) OVER () AS DECIMAL(5,1))                 AS pct_of_revenue,
       CAST(100.0 * SUM(SUM(revenue_usd)) OVER (ORDER BY decile) / SUM(SUM(revenue_usd)) OVER () AS DECIMAL(5,1)) AS cumulative_pct
FROM deciles
GROUP BY decile
ORDER BY decile;
GO

/* ---------------------------------------------------------------------
   Q08  Are deeper discounts hurting margin? Promotion depth and gross margin by year.
   Techniques: LEFT JOIN to promotions, weighted discount rate (not an average of averages), grouping with COALESCE
   Insight to look for: Black Friday discount deepens every year (20% -> 25% -> 30%) and margin follows it down.
   --------------------------------------------------------------------- */
SELECT YEAR(sl.order_date)                                                           AS order_year,
       COALESCE(p.promo_type, 'No promotion')                                        AS promo_type,
       COUNT(DISTINCT sl.order_id)                                                   AS orders,
       CAST(SUM(sl.net_revenue_usd) AS DECIMAL(18,0))                                AS net_revenue_usd,
       CAST(100.0 * SUM(sl.discount_usd) / SUM(sl.gross_revenue_usd) AS DECIMAL(5,1)) AS effective_discount_pct,
       CAST(100.0 * (1 - SUM(sl.cogs_usd) / SUM(sl.net_revenue_usd)) AS DECIMAL(5,1)) AS gross_margin_pct
FROM rpt.vw_sales_line AS sl
LEFT JOIN dw.dim_promotion AS p ON p.promo_id = sl.promo_id
WHERE sl.is_valid_sale = 1
  AND COALESCE(p.promo_type, 'No promotion') IN ('Black Friday', 'Clearance', 'No promotion')
GROUP BY YEAR(sl.order_date), COALESCE(p.promo_type, 'No promotion')
ORDER BY promo_type, order_year;
GO

/* ---------------------------------------------------------------------
   Q09  How much of reported growth is just currency? Reported vs constant-currency growth (Jan-Sep, like for like).
   Techniques: re-pricing current local revenue at LAST YEAR's monthly rates (self-join on the fx table with DATEADD),
               LAG over a partition, like-for-like period filter
   Insight to look for: Turkey grows far faster in local currency than in USD because the lira keeps depreciating.
   --------------------------------------------------------------------- */
WITH reported AS (
    SELECT country_code, YEAR(order_date) AS yr, SUM(net_revenue_usd) AS reported_usd
    FROM rpt.vw_sales_line
    WHERE is_valid_sale = 1 AND MONTH(order_date) <= 9
    GROUP BY country_code, YEAR(order_date)
),
constant_cur AS (
    SELECT sl.country_code, YEAR(sl.order_date) AS yr, SUM(sl.net_revenue_local * fx_py.rate_to_usd) AS cc_usd
    FROM rpt.vw_sales_line AS sl
    JOIN dw.fx_rate        AS fx_py ON fx_py.currency_code = sl.currency_code
                                   AND fx_py.month_start   = DATEADD(YEAR, -1, sl.month_start)
    WHERE sl.is_valid_sale = 1 AND MONTH(sl.order_date) <= 9
    GROUP BY sl.country_code, YEAR(sl.order_date)
),
joined AS (
    SELECT r.country_code, r.yr, r.reported_usd, c.cc_usd,
           LAG(r.reported_usd) OVER (PARTITION BY r.country_code ORDER BY r.yr) AS prior_year_usd
    FROM reported AS r
    LEFT JOIN constant_cur AS c ON c.country_code = r.country_code AND c.yr = r.yr
)
SELECT country_code, yr,
       CAST(reported_usd AS DECIMAL(18,0))                                                     AS reported_usd,
       CAST(100.0 * (reported_usd / prior_year_usd - 1) AS DECIMAL(6,1))                       AS reported_growth_pct,
       CAST(100.0 * (cc_usd       / prior_year_usd - 1) AS DECIMAL(6,1))                       AS constant_currency_growth_pct,
       CAST(100.0 * ((reported_usd - cc_usd) / prior_year_usd) AS DECIMAL(6,1))                AS fx_impact_pts
FROM joined
WHERE prior_year_usd IS NOT NULL AND yr >= 2025
ORDER BY country_code, yr;
GO

/* ---------------------------------------------------------------------
   Q10  Which carrier is failing? Quarterly late-delivery rate versus all OTHER carriers, with an automatic alert.
   Techniques: conditional aggregation, window SUM per quarter to build a peer benchmark that excludes the carrier itself,
               LAG for the quarter-on-quarter move, rule-based alert (a stable benchmark does not 'learn' the problem the way a moving average does)
   --------------------------------------------------------------------- */
WITH quarterly AS (
    SELECT carrier,
           DATEFROMPARTS(YEAR(delivery_date), (DATEPART(QUARTER, delivery_date) - 1) * 3 + 1, 1) AS quarter_start,
           COUNT(*)                                                                            AS deliveries,
           SUM(CASE WHEN delivery_date > promised_delivery_date THEN 1 ELSE 0 END)             AS late_deliveries
    FROM dw.fact_orders
    WHERE order_status = 'Completed' AND carrier IS NOT NULL
    GROUP BY carrier, DATEFROMPARTS(YEAR(delivery_date), (DATEPART(QUARTER, delivery_date) - 1) * 3 + 1, 1)
),
benchmarked AS (
    SELECT *,
           100.0 * late_deliveries / deliveries AS late_pct,
           100.0 * (SUM(late_deliveries) OVER (PARTITION BY quarter_start) - late_deliveries)
                 / NULLIF(SUM(deliveries) OVER (PARTITION BY quarter_start) - deliveries, 0) AS other_carriers_late_pct
    FROM quarterly
),
trend AS (
    SELECT *, LAG(late_pct) OVER (PARTITION BY carrier ORDER BY quarter_start) AS prev_quarter_late_pct
    FROM benchmarked
)
SELECT carrier, quarter_start, deliveries,
       CAST(late_pct AS DECIMAL(5,1))                  AS late_pct,
       CAST(prev_quarter_late_pct AS DECIMAL(5,1))     AS prev_quarter_late_pct,
       CAST(other_carriers_late_pct AS DECIMAL(5,1))   AS other_carriers_late_pct,
       CASE WHEN deliveries >= 100 AND late_pct > 2 * other_carriers_late_pct THEN 'ALERT' ELSE '' END AS alert
FROM trend
WHERE carrier IN ('SwiftCargo', 'AnatolianPost') AND quarter_start >= '2024-10-01'
ORDER BY carrier, quarter_start;
GO

/* ---------------------------------------------------------------------
   Q11  Which products are returned far more often than their category norm?
   Techniques: pooled category rate via window SUM, ratio-to-benchmark, minimum-volume filter to avoid small-sample noise
   --------------------------------------------------------------------- */
WITH sold AS (
    SELECT product_id, category, SUM(quantity) AS units_sold
    FROM rpt.vw_sales_line
    WHERE order_status = 'Completed'
    GROUP BY product_id, category
),
returned AS (
    SELECT l.product_id, SUM(r.return_qty) AS units_returned
    FROM dw.fact_returns AS r
    JOIN dw.fact_order_lines AS l ON l.order_line_id = r.order_line_id
    GROUP BY l.product_id
),
rates AS (
    SELECT s.product_id, s.category, s.units_sold, COALESCE(r.units_returned, 0) AS units_returned
    FROM sold AS s
    LEFT JOIN returned AS r ON r.product_id = s.product_id
),
benchmarked AS (
    SELECT *,
           100.0 * units_returned / units_sold                                                                   AS return_rate_pct,
           100.0 * SUM(units_returned) OVER (PARTITION BY category) / SUM(units_sold) OVER (PARTITION BY category) AS category_rate_pct
    FROM rates
)
SELECT b.category, p.product_name, p.supplier_id, b.units_sold, b.units_returned,
       CAST(b.return_rate_pct   AS DECIMAL(5,1)) AS return_rate_pct,
       CAST(b.category_rate_pct AS DECIMAL(5,1)) AS category_rate_pct,
       CAST(b.return_rate_pct / b.category_rate_pct AS DECIMAL(5,1)) AS times_category_norm
FROM benchmarked AS b
JOIN dw.dim_product AS p ON p.product_id = b.product_id
WHERE b.units_sold >= 200 AND b.return_rate_pct >= 2 * b.category_rate_pct
ORDER BY times_category_norm DESC;
GO

/* ---------------------------------------------------------------------
   Q12  Is a supplier's quality getting worse? Defective share of returns per supplier and year.
   Techniques: conditional aggregation over returns joined through lines to products and suppliers
   Insight to look for: supplier S05 (tents) - cost +14% and defects up after March 2025.
   --------------------------------------------------------------------- */
SELECT s.supplier_id, s.supplier_name, YEAR(r.return_date) AS return_year,
       SUM(r.return_qty)                                                                                   AS units_returned,
       CAST(100.0 * SUM(CASE WHEN r.return_reason = 'Defective/Faulty' THEN r.return_qty ELSE 0 END)
                  / SUM(r.return_qty) AS DECIMAL(5,1))                                                     AS defective_share_pct
FROM dw.fact_returns     AS r
JOIN dw.fact_order_lines AS l ON l.order_line_id = r.order_line_id
JOIN dw.dim_product      AS p ON p.product_id    = l.product_id
JOIN dw.dim_supplier     AS s ON s.supplier_id   = p.supplier_id
WHERE s.supplier_id IN ('S05', 'S01', 'S07')
GROUP BY s.supplier_id, s.supplier_name, YEAR(r.return_date)
ORDER BY s.supplier_id, return_year;
GO

/* ---------------------------------------------------------------------
   Q13  Inventory health at the latest month-end: stock-out risk, overstock and dead stock by category.
   Techniques: semi-additive measure (latest snapshot only, never summed across months), 90-day sales velocity,
               days of cover, CASE classification
   --------------------------------------------------------------------- */
WITH latest AS (
    SELECT MAX(snapshot_date) AS snap FROM dw.fact_inventory_snapshot
),
stock AS (
    SELECT product_id, SUM(units_on_hand) AS on_hand, SUM(units_on_hand * unit_cost_usd) AS value_usd
    FROM dw.fact_inventory_snapshot
    WHERE snapshot_date = (SELECT snap FROM latest)
    GROUP BY product_id
),
velocity AS (
    SELECT product_id, SUM(quantity) / 90.0 AS units_per_day
    FROM rpt.vw_sales_line
    WHERE is_valid_sale = 1 AND order_date > DATEADD(DAY, -90, (SELECT snap FROM latest))
    GROUP BY product_id
),
coverage AS (
    SELECT st.product_id, p.category, st.on_hand, st.value_usd, COALESCE(v.units_per_day, 0) AS units_per_day,
           CASE WHEN COALESCE(v.units_per_day, 0) = 0 THEN NULL ELSE st.on_hand / v.units_per_day END AS days_of_cover
    FROM stock AS st
    JOIN dw.dim_product AS p ON p.product_id = st.product_id
    LEFT JOIN velocity  AS v ON v.product_id = st.product_id
),
classified AS (
    SELECT *, CASE WHEN on_hand > 0 AND units_per_day = 0 THEN '4 Dead stock (no sales in 90 days)'
                   WHEN days_of_cover < 30               THEN '1 Stock-out risk (< 30 days)'
                   WHEN days_of_cover > 180              THEN '3 Overstock (> 180 days)'
                   ELSE '2 Healthy' END AS health
    FROM coverage
)
SELECT health,
       COUNT(*)                                       AS skus,
       SUM(on_hand)                                   AS units_on_hand,
       CAST(SUM(value_usd) AS DECIMAL(18,0))          AS inventory_value_usd,
       CAST(100.0 * SUM(value_usd) / SUM(SUM(value_usd)) OVER () AS DECIMAL(5,1)) AS pct_of_inventory_value
FROM classified
GROUP BY health
ORDER BY health;
GO

/* ---------------------------------------------------------------------
   Q14  What does a new customer really cost per channel, and how much do ad platforms over-claim?
   Techniques: reporting-view reuse, CAC = spend / real new customers, platform-claim ratio, YoY change with LAG
   Insight to look for: Meta CAC keeps rising; platforms report 1.5x-2.4x more conversions than real new customers.
   --------------------------------------------------------------------- */
WITH yearly AS (
    SELECT YEAR(m.month_start) AS yr, m.channel_name,
           SUM(m.spend_usd)            AS spend_usd,
           SUM(m.new_customers)        AS new_customers,
           SUM(m.platform_conversions) AS platform_conversions
    FROM rpt.vw_marketing_monthly AS m
    JOIN dw.dim_marketing_channel AS c ON c.channel_name = m.channel_name
    WHERE c.is_paid = 1 AND m.channel_name IN ('Google Ads', 'Meta Ads', 'TikTok Ads', 'Influencer', 'Affiliate')
    GROUP BY YEAR(m.month_start), m.channel_name
),
metrics AS (
    SELECT *, spend_usd / NULLIF(new_customers, 0) AS cac_usd FROM yearly
)
SELECT channel_name, yr,
       CAST(spend_usd AS DECIMAL(18,0))                                                       AS spend_usd,
       new_customers,
       CAST(cac_usd AS DECIMAL(8,0))                                                          AS cac_usd,
       CAST(100.0 * (cac_usd / NULLIF(LAG(cac_usd) OVER (PARTITION BY channel_name ORDER BY yr), 0) - 1) AS DECIMAL(6,1)) AS cac_change_yoy_pct,
       CAST(1.0 * platform_conversions / NULLIF(new_customers, 0) AS DECIMAL(5,2))            AS platform_claim_ratio
FROM metrics
WHERE yr < 2026
ORDER BY channel_name, yr;
GO

/* ---------------------------------------------------------------------
   Q15  Where did we miss the revenue target? Worst country-quarters, ranked.
   Techniques: actual vs target join at month grain, re-aggregation to quarter, RANK(), TOP
   --------------------------------------------------------------------- */
WITH actual AS (
    SELECT month_start, country_code, SUM(net_revenue_usd) AS actual_usd
    FROM rpt.vw_sales_line
    WHERE is_valid_sale = 1
    GROUP BY month_start, country_code
),
target AS (
    SELECT month_start, country_code, SUM(target_net_revenue_usd) AS target_usd
    FROM dw.fact_targets
    GROUP BY month_start, country_code
),
quarterly AS (
    SELECT YEAR(a.month_start) AS yr, DATEPART(QUARTER, a.month_start) AS qtr, a.country_code,
           SUM(a.actual_usd) AS actual_usd, SUM(t.target_usd) AS target_usd
    FROM actual AS a
    JOIN target AS t ON t.month_start = a.month_start AND t.country_code = a.country_code
    GROUP BY YEAR(a.month_start), DATEPART(QUARTER, a.month_start), a.country_code
)
SELECT TOP (10)
       yr, qtr, country_code,
       CAST(actual_usd AS DECIMAL(18,0))                             AS actual_usd,
       CAST(target_usd AS DECIMAL(18,0))                             AS target_usd,
       CAST(100.0 * (actual_usd / target_usd - 1) AS DECIMAL(6,1))   AS variance_pct,
       RANK() OVER (ORDER BY actual_usd / target_usd ASC)            AS miss_rank
FROM quarterly
ORDER BY miss_rank;
GO

/* ---------------------------------------------------------------------
   Q16  Gaps and islands: the longest streaks of consecutive months with stock-outs.
   Techniques: ROW_NUMBER minus month index = constant per island of consecutive months, GROUP BY island, HAVING
   --------------------------------------------------------------------- */
WITH stockout_months AS (
    SELECT product_id, warehouse_id, snapshot_date,
           YEAR(snapshot_date) * 12 + MONTH(snapshot_date)                                       AS month_index,
           ROW_NUMBER() OVER (PARTITION BY product_id, warehouse_id ORDER BY snapshot_date)       AS rn
    FROM dw.fact_inventory_snapshot
    WHERE stockout_days > 0
),
islands AS (
    SELECT *, month_index - rn AS island_key FROM stockout_months
)
SELECT TOP (10)
       i.product_id, p.product_name, i.warehouse_id,
       MIN(i.snapshot_date) AS streak_start,
       MAX(i.snapshot_date) AS streak_end,
       COUNT(*)             AS consecutive_months
FROM islands AS i
JOIN dw.dim_product AS p ON p.product_id = i.product_id
GROUP BY i.product_id, p.product_name, i.warehouse_id, i.island_key
HAVING COUNT(*) >= 2
ORDER BY consecutive_months DESC, streak_start;
GO

/* ---------------------------------------------------------------------
   Q17  Does late delivery hurt customer satisfaction?
   Techniques: join tickets to orders, CASE-derived grouping, AVG on a CAST FLOAT (AVG of a DECIMAL(2,1) would truncate)
   --------------------------------------------------------------------- */
SELECT CASE WHEN o.delivery_date > o.promised_delivery_date THEN 'Delivered late' ELSE 'Delivered on time' END AS delivery_outcome,
       COUNT(*)                                                         AS surveys_answered,
       CAST(AVG(CAST(t.csat_score AS FLOAT)) AS DECIMAL(4,2))           AS avg_csat,
       CAST(100.0 * SUM(CASE WHEN t.csat_score <= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS pct_unhappy_1_2
FROM dw.fact_support_tickets AS t
JOIN dw.fact_orders          AS o ON o.order_id = t.order_id
WHERE t.csat_score IS NOT NULL AND o.order_status = 'Completed'
GROUP BY CASE WHEN o.delivery_date > o.promised_delivery_date THEN 'Delivered late' ELSE 'Delivered on time' END
ORDER BY avg_csat;
GO
