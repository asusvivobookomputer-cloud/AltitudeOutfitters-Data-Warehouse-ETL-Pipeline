/* =====================================================================
   08 - Parameterised procedures and an inline table-valued function for BI tools and apps
   Project : Altitude Outfitters - SQL Server Data Warehouse & Analytics
   Engine  : Microsoft SQL Server 2017+ (T-SQL, written for SSMS 19/20)
   ===================================================================== */
USE AltitudeOutfitters;
GO

/* Revenue summary by month for any period, optionally filtered by country and channel.
   Usage:  EXEC rpt.usp_revenue_summary @FromDate = '2025-01-01', @ToDate = '2025-12-31', @CountryCode = 'TR';  */
CREATE OR ALTER PROCEDURE rpt.usp_revenue_summary
    @FromDate     DATE,
    @ToDate       DATE,
    @CountryCode  CHAR(2)     = NULL,
    @Channel      VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate > @ToDate
        THROW 50001, 'FromDate must be earlier than or equal to ToDate.', 1;

    SELECT oe.month_start,
           COUNT(*)                                                                         AS orders,
           CAST(SUM(oe.net_revenue_usd) AS DECIMAL(18,0))                                   AS net_revenue_usd,
           CAST(100.0 * (1 - SUM(oe.cogs_usd) / NULLIF(SUM(oe.net_revenue_usd), 0)) AS DECIMAL(5,1))        AS gross_margin_pct,
           CAST(100.0 * SUM(oe.contribution_margin_usd) / NULLIF(SUM(oe.net_revenue_usd), 0) AS DECIMAL(5,1)) AS contribution_margin_pct,
           CAST(SUM(oe.net_revenue_usd) / NULLIF(COUNT(*), 0) AS DECIMAL(10,2))             AS avg_order_value_usd
    FROM rpt.vw_order_economics AS oe
    WHERE oe.is_valid_sale = 1
      AND oe.order_date BETWEEN @FromDate AND @ToDate
      AND (@CountryCode IS NULL OR oe.country_code = @CountryCode)
      AND (@Channel     IS NULL OR oe.channel      = @Channel)
    GROUP BY oe.month_start
    ORDER BY oe.month_start;
END;
GO

/* Customer list for one RFM segment as of any date (e.g. a CRM export of "At Risk" customers).
   Usage:  EXEC rpt.usp_customers_by_rfm_segment @Segment = 'At Risk', @MinMonetaryUsd = 500;  */
CREATE OR ALTER PROCEDURE rpt.usp_customers_by_rfm_segment
    @Segment         VARCHAR(30),
    @AsOfDate        DATE          = NULL,
    @MinMonetaryUsd  DECIMAL(18,2) = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @as_of DATE = COALESCE(@AsOfDate, (SELECT MAX(order_date) FROM rpt.vw_customer_order));

    WITH base AS (
        SELECT customer_id,
               DATEDIFF(DAY, MAX(order_date), @as_of) AS recency_days,
               COUNT(*)                               AS frequency,
               SUM(net_revenue_usd)                   AS monetary_usd
        FROM rpt.vw_customer_order
        WHERE order_date <= @as_of
        GROUP BY customer_id
    ),
    scored AS (
        SELECT *, NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
               CASE WHEN frequency >= 5 THEN 5 ELSE frequency END AS f_score
        FROM base
    ),
    segmented AS (
        SELECT *, CASE WHEN r_score >= 4 AND f_score >= 4 THEN 'Champions'
                       WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal'
                       WHEN r_score >= 4 AND f_score <= 2 THEN 'New / Promising'
                       WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
                       WHEN r_score <= 2 AND f_score <= 2 THEN 'Hibernating'
                       ELSE 'Needs Attention' END AS segment
        FROM scored
    )
    SELECT s.customer_id, c.country_code, c.city, c.acquisition_channel, c.email_opt_in,
           s.recency_days, s.frequency, CAST(s.monetary_usd AS DECIMAL(18,2)) AS monetary_usd, s.segment
    FROM segmented AS s
    JOIN dw.dim_customer AS c ON c.customer_id = s.customer_id
    WHERE s.segment = @Segment AND s.monetary_usd >= @MinMonetaryUsd
    ORDER BY s.monetary_usd DESC;
END;
GO

/* Inline table-valued function: monthly net revenue for one country - handy as a Power BI source or inside joins.
   Usage:  SELECT * FROM rpt.fn_monthly_revenue('AZ') ORDER BY month_start;  */
CREATE OR ALTER FUNCTION rpt.fn_monthly_revenue (@CountryCode CHAR(2))
RETURNS TABLE
AS
RETURN
(
    SELECT month_start, SUM(net_revenue_usd) AS net_revenue_usd, SUM(quantity) AS units
    FROM rpt.vw_sales_line
    WHERE is_valid_sale = 1 AND country_code = @CountryCode
    GROUP BY month_start
);
GO
