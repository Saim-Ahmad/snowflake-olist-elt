-- 06_dynamic_table.sql
USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;

CREATE OR REPLACE DYNAMIC TABLE olist_dw.marts.dt_daily_sales
  TARGET_LAG = '12 hours'
  WAREHOUSE = wh_etl
  REFRESH_MODE = INCREMENTAL
  INITIALIZE = ON_CREATE
AS
SELECT o.purchased_at::DATE AS order_date,
       c.state              AS customer_state,
       COUNT(*)             AS items_sold,
       SUM(i.price)         AS revenue,
       SUM(i.freight_value) AS freight,
       SUM(IFF(o.delivered_at > o.estimated_delivery_at, 1, 0)) AS late_items
FROM olist_dw.staging.order_items i
JOIN olist_dw.staging.orders o    ON o.order_id = i.order_id
JOIN olist_dw.staging.customers c ON c.customer_id = o.customer_id
WHERE o.order_status <> 'canceled'
GROUP BY 1, 2;

-- Verify 1: refresh mode must say INCREMENTAL
SHOW DYNAMIC TABLES LIKE 'DT_DAILY_SALES' IN SCHEMA olist_dw.marts;

-- Verify 2: reconcile against the source (the two numbers must match)
SELECT (SELECT SUM(revenue) FROM olist_dw.marts.dt_daily_sales) AS dt_revenue,
       (SELECT SUM(i.price)
          FROM olist_dw.staging.order_items i
          JOIN olist_dw.staging.orders o ON o.order_id = i.order_id
         WHERE o.order_status <> 'canceled') AS source_revenue;

-- Demo: cancel every order from Black Friday 2017, refresh, compare
SET d = '2017-11-24'::DATE;

CREATE OR REPLACE TABLE olist_dw.audit.tmp_status_backup AS
SELECT order_id, order_status FROM olist_dw.staging.orders WHERE purchased_at::DATE = $d;

SELECT SUM(revenue) AS revenue_before
FROM olist_dw.marts.dt_daily_sales WHERE order_date = $d;

UPDATE olist_dw.staging.orders SET order_status = 'canceled'
WHERE purchased_at::DATE = $d AND order_status <> 'canceled';

ALTER DYNAMIC TABLE olist_dw.marts.dt_daily_sales REFRESH;

SELECT SUM(revenue) AS revenue_after_cancel   -- expect NULL
FROM olist_dw.marts.dt_daily_sales WHERE order_date = $d;

SELECT refresh_action, refresh_trigger, state, data_timestamp, statistics
FROM TABLE(olist_dw.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
       NAME => 'OLIST_DW.MARTS.DT_DAILY_SALES'))
ORDER BY data_timestamp DESC;

-- Revert, refresh, confirm the original revenue comes back
UPDATE olist_dw.staging.orders o
   SET order_status = b.order_status
  FROM olist_dw.audit.tmp_status_backup b
 WHERE o.order_id = b.order_id;

ALTER DYNAMIC TABLE olist_dw.marts.dt_daily_sales REFRESH;

SELECT SUM(revenue) AS revenue_restored
FROM olist_dw.marts.dt_daily_sales WHERE order_date = $d;

DROP TABLE olist_dw.audit.tmp_status_backup;

-- Stop background refreshes
ALTER DYNAMIC TABLE olist_dw.marts.dt_daily_sales SUSPEND;
