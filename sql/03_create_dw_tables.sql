/* =====================================================================
   03 - Create the clean data warehouse (star schema) in schema [dw]
   Project : Altitude Outfitters - SQL Server Data Warehouse & Analytics
   Engine  : Microsoft SQL Server 2017+ (T-SQL, written for SSMS 19/20)
   Typed columns, primary keys, foreign keys, check constraints and indexes.
   ===================================================================== */
USE AltitudeOutfitters;
GO

/* ---- drop in dependency order (idempotent re-run) ---- */
DROP TABLE IF EXISTS dw.fact_web_sessions, dw.fact_marketing_budget, dw.fact_marketing_spend, dw.fact_targets,
                     dw.fact_inventory_snapshot, dw.fact_support_tickets, dw.fact_returns, dw.fact_order_lines, dw.fact_orders,
                     dw.fx_rate, dw.dim_date, dw.dim_customer, dw.dim_product, dw.dim_promotion, dw.dim_store,
                     dw.dim_warehouse, dw.dim_supplier, dw.dim_marketing_channel, dw.channel_alias, dw.dim_geography;
GO

/* ============================ DIMENSIONS ============================ */
CREATE TABLE dw.dim_geography (
    country_code   CHAR(2)       NOT NULL CONSTRAINT PK_dim_geography PRIMARY KEY,
    country_name   NVARCHAR(60)  NOT NULL,
    region         NVARCHAR(60)  NOT NULL,
    currency_code  CHAR(3)       NOT NULL,
    latitude       DECIMAL(9,6)  NULL,
    longitude      DECIMAL(9,6)  NULL
);

CREATE TABLE dw.dim_supplier (
    supplier_id         CHAR(3)       NOT NULL CONSTRAINT PK_dim_supplier PRIMARY KEY,
    supplier_name       NVARCHAR(80)  NOT NULL,
    country             NVARCHAR(60)  NOT NULL,
    lead_time_days      INT           NOT NULL,
    quality_rating      DECIMAL(3,1)  NOT NULL CONSTRAINT CK_supplier_rating CHECK (quality_rating BETWEEN 1 AND 5),
    payment_terms_days  INT           NOT NULL
);

CREATE TABLE dw.dim_warehouse (
    warehouse_id    CHAR(6)       NOT NULL CONSTRAINT PK_dim_warehouse PRIMARY KEY,
    warehouse_name  NVARCHAR(80)  NOT NULL,
    city            NVARCHAR(60)  NOT NULL,
    country_code    CHAR(2)       NOT NULL CONSTRAINT FK_wh_geo REFERENCES dw.dim_geography(country_code),
    open_date       DATE          NOT NULL
);

CREATE TABLE dw.dim_store (
    store_id                    VARCHAR(10)   NOT NULL CONSTRAINT PK_dim_store PRIMARY KEY,
    store_name                  NVARCHAR(80)  NOT NULL,
    channel                     VARCHAR(20)   NOT NULL CONSTRAINT CK_store_channel CHECK (channel IN ('Web','Marketplace','Retail','B2B')),
    country_code                CHAR(2)       NOT NULL CONSTRAINT FK_store_geo REFERENCES dw.dim_geography(country_code),
    city                        NVARCHAR(60)  NOT NULL,
    open_date                   DATE          NOT NULL,
    marketplace_commission_pct  DECIMAL(5,4)  NOT NULL,
    payment_fee_pct             DECIMAL(5,4)  NOT NULL
);

CREATE TABLE dw.dim_promotion (
    promo_id        CHAR(5)       NOT NULL CONSTRAINT PK_dim_promotion PRIMARY KEY,
    promo_name      NVARCHAR(80)  NOT NULL,
    promo_type      NVARCHAR(40)  NOT NULL,
    start_date      DATE          NOT NULL,
    end_date        DATE          NOT NULL,
    discount_pct    DECIMAL(5,2)  NOT NULL,
    channel_scope   NVARCHAR(40)  NOT NULL,
    country_scope   NVARCHAR(40)  NOT NULL,
    category_scope  NVARCHAR(200) NOT NULL
);

CREATE TABLE dw.dim_marketing_channel (
    channel_name   NVARCHAR(40) NOT NULL CONSTRAINT PK_dim_marketing_channel PRIMARY KEY,
    channel_group  NVARCHAR(40) NOT NULL,
    is_paid        BIT          NOT NULL
);

/* alias table = the standard way to clean inconsistent labels without hard-coding them in every query */
CREATE TABLE dw.channel_alias (
    alias_name      NVARCHAR(60) NOT NULL CONSTRAINT PK_channel_alias PRIMARY KEY,
    channel_name    NVARCHAR(40) NOT NULL CONSTRAINT FK_alias_channel REFERENCES dw.dim_marketing_channel(channel_name)
);

CREATE TABLE dw.dim_product (
    product_id         CHAR(5)        NOT NULL CONSTRAINT PK_dim_product PRIMARY KEY,
    sku                VARCHAR(30)    NOT NULL,
    product_name       NVARCHAR(120)  NOT NULL,
    category           NVARCHAR(40)   NOT NULL,
    subcategory        NVARCHAR(40)   NOT NULL,
    brand              NVARCHAR(40)   NOT NULL,
    brand_type         NVARCHAR(20)   NOT NULL,
    supplier_id        CHAR(3)        NOT NULL CONSTRAINT FK_product_supplier REFERENCES dw.dim_supplier(supplier_id),
    list_price_usd     DECIMAL(10,2)  NOT NULL,
    standard_cost_usd  DECIMAL(10,2)  NOT NULL,
    launch_date        DATE           NOT NULL,
    discontinued_date  DATE           NULL,
    weight_kg          DECIMAL(6,2)   NULL
);

CREATE TABLE dw.dim_customer (
    customer_id          CHAR(7)       NOT NULL CONSTRAINT PK_dim_customer PRIMARY KEY,
    signup_date          DATE          NOT NULL,
    customer_type        VARCHAR(10)   NOT NULL,
    country_code         CHAR(2)       NOT NULL CONSTRAINT FK_customer_geo REFERENCES dw.dim_geography(country_code),
    city                 NVARCHAR(60)  NULL,
    gender               VARCHAR(12)   NOT NULL,
    birth_date           DATE          NULL,
    acquisition_channel  NVARCHAR(40)  NOT NULL CONSTRAINT FK_customer_channel REFERENCES dw.dim_marketing_channel(channel_name),
    email_opt_in         BIT           NOT NULL
);

CREATE TABLE dw.dim_date (
    date_key       INT          NOT NULL CONSTRAINT PK_dim_date PRIMARY KEY,   -- yyyymmdd
    date_value     DATE         NOT NULL,
    [year]         SMALLINT     NOT NULL,
    [quarter]      TINYINT      NOT NULL,
    month_number   TINYINT      NOT NULL,
    month_name     VARCHAR(12)  NOT NULL,
    month_start    DATE         NOT NULL,
    iso_weekday    TINYINT      NOT NULL,       -- 1 = Monday ... 7 = Sunday
    day_name       VARCHAR(12)  NOT NULL,
    is_weekend     BIT          NOT NULL
);

CREATE TABLE dw.fx_rate (
    month_start    DATE          NOT NULL,
    currency_code  CHAR(3)       NOT NULL,
    rate_to_usd    DECIMAL(12,6) NOT NULL,      -- 1 unit of local currency = rate_to_usd USD
    CONSTRAINT PK_fx_rate PRIMARY KEY (month_start, currency_code)
);

/* ============================== FACTS =============================== */
CREATE TABLE dw.fact_orders (
    order_id                CHAR(10)       NOT NULL CONSTRAINT PK_fact_orders PRIMARY KEY,
    order_datetime          DATETIME2(0)   NOT NULL,
    order_date              DATE           NOT NULL,
    customer_id             CHAR(7)        NULL CONSTRAINT FK_orders_customer REFERENCES dw.dim_customer(customer_id),  -- NULL = anonymous marketplace order
    store_id                VARCHAR(10)    NOT NULL CONSTRAINT FK_orders_store REFERENCES dw.dim_store(store_id),
    ship_to_country         CHAR(2)        NOT NULL CONSTRAINT FK_orders_geo REFERENCES dw.dim_geography(country_code),
    promo_id                CHAR(5)        NULL CONSTRAINT FK_orders_promo REFERENCES dw.dim_promotion(promo_id),
    currency_code           CHAR(3)        NOT NULL,
    payment_method          NVARCHAR(40)   NOT NULL,
    order_status            VARCHAR(12)    NOT NULL CONSTRAINT CK_order_status CHECK (order_status IN ('Completed','Cancelled','Shipped','Processing')),
    fulfilment_type         VARCHAR(20)    NOT NULL,
    carrier                 NVARCHAR(40)   NULL,
    ship_date               DATE           NULL,
    promised_delivery_date  DATE           NULL,
    delivery_date           DATE           NULL,
    shipping_fee_local      DECIMAL(12,2)  NOT NULL,
    shipping_cost_usd       DECIMAL(12,2)  NOT NULL
);

CREATE TABLE dw.fact_order_lines (
    order_line_id     CHAR(8)        NOT NULL CONSTRAINT PK_fact_order_lines PRIMARY KEY,
    order_id          CHAR(10)       NOT NULL CONSTRAINT FK_lines_order REFERENCES dw.fact_orders(order_id),
    product_id        CHAR(5)        NOT NULL CONSTRAINT FK_lines_product REFERENCES dw.dim_product(product_id),
    quantity          INT            NOT NULL CONSTRAINT CK_lines_qty CHECK (quantity > 0),
    unit_price_local  DECIMAL(12,2)  NOT NULL,
    discount_pct      DECIMAL(5,2)   NOT NULL CONSTRAINT CK_lines_disc CHECK (discount_pct BETWEEN 0 AND 1),
    unit_cost_usd     DECIMAL(12,2)  NOT NULL
);

CREATE TABLE dw.fact_returns (
    return_id            CHAR(7)        NOT NULL CONSTRAINT PK_fact_returns PRIMARY KEY,
    order_line_id        CHAR(8)        NOT NULL CONSTRAINT FK_returns_line REFERENCES dw.fact_order_lines(order_line_id),
    return_date          DATE           NOT NULL,
    return_qty           INT            NOT NULL,
    return_reason        NVARCHAR(40)   NOT NULL,
    item_condition       NVARCHAR(30)   NOT NULL,
    refund_amount_local  DECIMAL(12,2)  NOT NULL,
    refund_status        NVARCHAR(20)   NOT NULL
);

CREATE TABLE dw.fact_support_tickets (
    ticket_id             CHAR(7)       NOT NULL CONSTRAINT PK_fact_support_tickets PRIMARY KEY,
    order_id              CHAR(10)      NOT NULL CONSTRAINT FK_tickets_order REFERENCES dw.fact_orders(order_id),
    created_at            DATETIME2(0)  NOT NULL,
    ticket_category       NVARCHAR(40)  NOT NULL,
    priority              NVARCHAR(10)  NOT NULL,
    contact_channel       NVARCHAR(20)  NOT NULL,
    first_response_hours  DECIMAL(8,1)  NOT NULL,
    resolution_hours      DECIMAL(8,1)  NOT NULL,
    csat_score            DECIMAL(2,1)  NULL        -- NULL = customer did not answer the survey
);

CREATE TABLE dw.fact_inventory_snapshot (
    snapshot_date  DATE           NOT NULL,        -- month end
    product_id     CHAR(5)        NOT NULL CONSTRAINT FK_inv_product   REFERENCES dw.dim_product(product_id),
    warehouse_id   CHAR(6)        NOT NULL CONSTRAINT FK_inv_warehouse REFERENCES dw.dim_warehouse(warehouse_id),
    units_on_hand  INT            NOT NULL,
    units_on_order INT            NOT NULL,
    stockout_days  INT            NOT NULL,
    unit_cost_usd  DECIMAL(10,2)  NOT NULL,
    CONSTRAINT PK_fact_inventory PRIMARY KEY (snapshot_date, product_id, warehouse_id)
);

CREATE TABLE dw.fact_marketing_spend (
    spend_date            DATE           NOT NULL,
    country_code          CHAR(2)        NOT NULL CONSTRAINT FK_spend_geo REFERENCES dw.dim_geography(country_code),
    channel_name          NVARCHAR(40)   NOT NULL CONSTRAINT FK_spend_channel REFERENCES dw.dim_marketing_channel(channel_name),
    spend_usd             DECIMAL(12,2)  NULL,      -- NULL = missing in source (kept, not silently turned into 0)
    is_spend_missing      BIT            NOT NULL,
    impressions           BIGINT         NOT NULL,
    clicks                BIGINT         NOT NULL,
    platform_conversions  INT            NOT NULL,
    platform_revenue_usd  DECIMAL(14,2)  NOT NULL,
    CONSTRAINT PK_fact_marketing_spend PRIMARY KEY (spend_date, country_code, channel_name)
);

CREATE TABLE dw.fact_web_sessions (
    week_start_date        DATE         NOT NULL,
    country_code           CHAR(2)      NOT NULL CONSTRAINT FK_sessions_geo REFERENCES dw.dim_geography(country_code),
    device_category        VARCHAR(10)  NOT NULL,
    traffic_source         NVARCHAR(40) NOT NULL CONSTRAINT FK_sessions_channel REFERENCES dw.dim_marketing_channel(channel_name),
    sessions               INT          NOT NULL,
    users                  INT          NOT NULL,
    bounced_sessions       INT          NOT NULL,
    product_view_sessions  INT          NOT NULL,
    add_to_cart_sessions   INT          NOT NULL,
    checkout_sessions      INT          NOT NULL,
    orders                 INT          NOT NULL,
    total_session_seconds  BIGINT       NOT NULL,
    CONSTRAINT PK_fact_web_sessions PRIMARY KEY (week_start_date, country_code, device_category, traffic_source)
);

CREATE TABLE dw.fact_targets (
    month_start              DATE           NOT NULL,
    country_code             CHAR(2)        NOT NULL CONSTRAINT FK_targets_geo REFERENCES dw.dim_geography(country_code),
    category                 NVARCHAR(40)   NOT NULL,
    target_net_revenue_usd   DECIMAL(14,2)  NOT NULL,
    target_gross_margin_pct  DECIMAL(5,3)   NOT NULL,
    CONSTRAINT PK_fact_targets PRIMARY KEY (month_start, country_code, category)
);

CREATE TABLE dw.fact_marketing_budget (
    month_start   DATE           NOT NULL,
    country_code  CHAR(2)        NOT NULL CONSTRAINT FK_budget_geo REFERENCES dw.dim_geography(country_code),
    channel_name  NVARCHAR(40)   NOT NULL CONSTRAINT FK_budget_channel REFERENCES dw.dim_marketing_channel(channel_name),
    budget_usd    DECIMAL(12,2)  NOT NULL,
    CONSTRAINT PK_fact_marketing_budget PRIMARY KEY (month_start, country_code, channel_name)
);
GO

/* ============ supporting indexes for the joins used by the reporting views ============ */
CREATE INDEX IX_orders_date_status   ON dw.fact_orders (order_date) INCLUDE (order_status, store_id, ship_to_country, customer_id, currency_code);
CREATE INDEX IX_orders_customer      ON dw.fact_orders (customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX IX_lines_order          ON dw.fact_order_lines (order_id) INCLUDE (product_id, quantity, unit_price_local, discount_pct, unit_cost_usd);
CREATE INDEX IX_lines_product        ON dw.fact_order_lines (product_id);
CREATE INDEX IX_returns_line         ON dw.fact_returns (order_line_id) INCLUDE (return_qty, refund_amount_local, return_reason);
CREATE INDEX IX_tickets_order        ON dw.fact_support_tickets (order_id);
CREATE INDEX IX_spend_month_channel  ON dw.fact_marketing_spend (channel_name, spend_date) INCLUDE (spend_usd, country_code);
GO
