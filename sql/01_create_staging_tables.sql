/* =====================================================================
   01 - Create staging tables
   Project : Altitude Outfitters - SQL Server Data Warehouse & Analytics
   Engine  : Microsoft SQL Server 2017+ (T-SQL, written for SSMS 19/20)
   Every staging column is NVARCHAR so that the CSV load never fails because of dirty values. Typing and cleaning happen in step 04.
   ===================================================================== */

USE AltitudeOutfitters;
GO
IF OBJECT_ID(N'stg.dim_customers', N'U') IS NOT NULL DROP TABLE stg.dim_customers;
CREATE TABLE stg.dim_customers (
    customer_id                NVARCHAR(400) NULL,
    signup_date                NVARCHAR(400) NULL,
    customer_type              NVARCHAR(400) NULL,
    country_code               NVARCHAR(400) NULL,
    city                       NVARCHAR(400) NULL,
    gender                     NVARCHAR(400) NULL,
    birth_date                 NVARCHAR(400) NULL,
    acquisition_channel        NVARCHAR(400) NULL,
    email_opt_in               NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.dim_geography', N'U') IS NOT NULL DROP TABLE stg.dim_geography;
CREATE TABLE stg.dim_geography (
    country_code               NVARCHAR(400) NULL,
    country_name               NVARCHAR(400) NULL,
    region                     NVARCHAR(400) NULL,
    currency_code              NVARCHAR(400) NULL,
    latitude                   NVARCHAR(400) NULL,
    longitude                  NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.dim_marketing_channels', N'U') IS NOT NULL DROP TABLE stg.dim_marketing_channels;
CREATE TABLE stg.dim_marketing_channels (
    channel_name               NVARCHAR(400) NULL,
    channel_group              NVARCHAR(400) NULL,
    is_paid                    NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.dim_products', N'U') IS NOT NULL DROP TABLE stg.dim_products;
CREATE TABLE stg.dim_products (
    product_id                 NVARCHAR(400) NULL,
    sku                        NVARCHAR(400) NULL,
    product_name               NVARCHAR(400) NULL,
    category                   NVARCHAR(400) NULL,
    subcategory                NVARCHAR(400) NULL,
    brand                      NVARCHAR(400) NULL,
    brand_type                 NVARCHAR(400) NULL,
    supplier_id                NVARCHAR(400) NULL,
    list_price_usd             NVARCHAR(400) NULL,
    standard_cost_usd          NVARCHAR(400) NULL,
    launch_date                NVARCHAR(400) NULL,
    discontinued_date          NVARCHAR(400) NULL,
    weight_kg                  NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.dim_promotions', N'U') IS NOT NULL DROP TABLE stg.dim_promotions;
CREATE TABLE stg.dim_promotions (
    promo_id                   NVARCHAR(400) NULL,
    promo_name                 NVARCHAR(400) NULL,
    promo_type                 NVARCHAR(400) NULL,
    start_date                 NVARCHAR(400) NULL,
    end_date                   NVARCHAR(400) NULL,
    discount_pct               NVARCHAR(400) NULL,
    channel_scope              NVARCHAR(400) NULL,
    country_scope              NVARCHAR(400) NULL,
    category_scope             NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.dim_stores', N'U') IS NOT NULL DROP TABLE stg.dim_stores;
CREATE TABLE stg.dim_stores (
    store_id                   NVARCHAR(400) NULL,
    store_name                 NVARCHAR(400) NULL,
    channel                    NVARCHAR(400) NULL,
    country_code               NVARCHAR(400) NULL,
    city                       NVARCHAR(400) NULL,
    open_date                  NVARCHAR(400) NULL,
    marketplace_commission_pct NVARCHAR(400) NULL,
    payment_fee_pct            NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.dim_suppliers', N'U') IS NOT NULL DROP TABLE stg.dim_suppliers;
CREATE TABLE stg.dim_suppliers (
    supplier_id                NVARCHAR(400) NULL,
    supplier_name              NVARCHAR(400) NULL,
    country                    NVARCHAR(400) NULL,
    lead_time_days             NVARCHAR(400) NULL,
    quality_rating             NVARCHAR(400) NULL,
    payment_terms_days         NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.dim_warehouses', N'U') IS NOT NULL DROP TABLE stg.dim_warehouses;
CREATE TABLE stg.dim_warehouses (
    warehouse_id               NVARCHAR(400) NULL,
    warehouse_name             NVARCHAR(400) NULL,
    city                       NVARCHAR(400) NULL,
    country_code               NVARCHAR(400) NULL,
    open_date                  NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fact_inventory_snapshot', N'U') IS NOT NULL DROP TABLE stg.fact_inventory_snapshot;
CREATE TABLE stg.fact_inventory_snapshot (
    snapshot_date              NVARCHAR(400) NULL,
    product_id                 NVARCHAR(400) NULL,
    warehouse_id               NVARCHAR(400) NULL,
    units_on_hand              NVARCHAR(400) NULL,
    units_on_order             NVARCHAR(400) NULL,
    stockout_days              NVARCHAR(400) NULL,
    unit_cost_usd              NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fact_marketing_budget', N'U') IS NOT NULL DROP TABLE stg.fact_marketing_budget;
CREATE TABLE stg.fact_marketing_budget (
    month_start                NVARCHAR(400) NULL,
    country_code               NVARCHAR(400) NULL,
    channel                    NVARCHAR(400) NULL,
    budget_usd                 NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fact_marketing_spend', N'U') IS NOT NULL DROP TABLE stg.fact_marketing_spend;
CREATE TABLE stg.fact_marketing_spend (
    date                       NVARCHAR(400) NULL,
    country_code               NVARCHAR(400) NULL,
    channel                    NVARCHAR(400) NULL,
    spend_usd                  NVARCHAR(400) NULL,
    impressions                NVARCHAR(400) NULL,
    clicks                     NVARCHAR(400) NULL,
    platform_conversions       NVARCHAR(400) NULL,
    platform_revenue_usd       NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fact_order_lines', N'U') IS NOT NULL DROP TABLE stg.fact_order_lines;
CREATE TABLE stg.fact_order_lines (
    order_line_id              NVARCHAR(400) NULL,
    order_id                   NVARCHAR(400) NULL,
    product_id                 NVARCHAR(400) NULL,
    quantity                   NVARCHAR(400) NULL,
    unit_price_local           NVARCHAR(400) NULL,
    discount_pct               NVARCHAR(400) NULL,
    unit_cost_usd              NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fact_orders', N'U') IS NOT NULL DROP TABLE stg.fact_orders;
CREATE TABLE stg.fact_orders (
    order_id                   NVARCHAR(400) NULL,
    order_datetime             NVARCHAR(400) NULL,
    customer_id                NVARCHAR(400) NULL,
    store_id                   NVARCHAR(400) NULL,
    ship_to_country            NVARCHAR(400) NULL,
    promo_id                   NVARCHAR(400) NULL,
    currency_code              NVARCHAR(400) NULL,
    payment_method             NVARCHAR(400) NULL,
    order_status               NVARCHAR(400) NULL,
    fulfilment_type            NVARCHAR(400) NULL,
    carrier                    NVARCHAR(400) NULL,
    ship_date                  NVARCHAR(400) NULL,
    promised_delivery_date     NVARCHAR(400) NULL,
    delivery_date              NVARCHAR(400) NULL,
    shipping_fee_local         NVARCHAR(400) NULL,
    shipping_cost_usd          NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fact_returns', N'U') IS NOT NULL DROP TABLE stg.fact_returns;
CREATE TABLE stg.fact_returns (
    return_id                  NVARCHAR(400) NULL,
    order_line_id              NVARCHAR(400) NULL,
    return_date                NVARCHAR(400) NULL,
    return_qty                 NVARCHAR(400) NULL,
    return_reason              NVARCHAR(400) NULL,
    item_condition             NVARCHAR(400) NULL,
    refund_amount_local        NVARCHAR(400) NULL,
    refund_status              NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fact_support_tickets', N'U') IS NOT NULL DROP TABLE stg.fact_support_tickets;
CREATE TABLE stg.fact_support_tickets (
    ticket_id                  NVARCHAR(400) NULL,
    order_id                   NVARCHAR(400) NULL,
    created_at                 NVARCHAR(400) NULL,
    ticket_category            NVARCHAR(400) NULL,
    priority                   NVARCHAR(400) NULL,
    contact_channel            NVARCHAR(400) NULL,
    first_response_hours       NVARCHAR(400) NULL,
    resolution_hours           NVARCHAR(400) NULL,
    csat_score                 NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fact_targets', N'U') IS NOT NULL DROP TABLE stg.fact_targets;
CREATE TABLE stg.fact_targets (
    month_start                NVARCHAR(400) NULL,
    country_code               NVARCHAR(400) NULL,
    category                   NVARCHAR(400) NULL,
    target_net_revenue_usd     NVARCHAR(400) NULL,
    target_gross_margin_pct    NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fact_web_sessions', N'U') IS NOT NULL DROP TABLE stg.fact_web_sessions;
CREATE TABLE stg.fact_web_sessions (
    week_start_date            NVARCHAR(400) NULL,
    country_code               NVARCHAR(400) NULL,
    device_category            NVARCHAR(400) NULL,
    traffic_source             NVARCHAR(400) NULL,
    sessions                   NVARCHAR(400) NULL,
    users                      NVARCHAR(400) NULL,
    bounced_sessions           NVARCHAR(400) NULL,
    product_view_sessions      NVARCHAR(400) NULL,
    add_to_cart_sessions       NVARCHAR(400) NULL,
    checkout_sessions          NVARCHAR(400) NULL,
    orders                     NVARCHAR(400) NULL,
    total_session_seconds      NVARCHAR(400) NULL
);
GO

IF OBJECT_ID(N'stg.fx_rates', N'U') IS NOT NULL DROP TABLE stg.fx_rates;
CREATE TABLE stg.fx_rates (
    month_start                NVARCHAR(400) NULL,
    currency_code              NVARCHAR(400) NULL,
    rate_to_usd                NVARCHAR(400) NULL
);
GO

