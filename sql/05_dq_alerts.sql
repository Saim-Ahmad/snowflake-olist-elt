-- 05_dq_alerts.sql
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE ALERT ON ACCOUNT TO ROLE SYSADMIN;

USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;

CREATE TABLE IF NOT EXISTS olist_dw.audit.dq_results (
  run_id      VARCHAR,
  run_at      TIMESTAMP_LTZ,
  check_name  VARCHAR,
  severity    VARCHAR,
  failed_rows NUMBER,
  total_rows  NUMBER
);

CREATE TABLE IF NOT EXISTS olist_dw.audit.alert_log (
  alerted_at TIMESTAMP_LTZ,
  message    VARCHAR
);

CREATE OR REPLACE VIEW olist_dw.audit.v_dq_latest AS
SELECT * FROM olist_dw.audit.dq_results
WHERE run_id = (SELECT run_id FROM olist_dw.audit.dq_results ORDER BY run_at DESC LIMIT 1);

CREATE OR REPLACE PROCEDURE olist_dw.audit.sp_run_dq()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  rid STRING;
  errs INT;
BEGIN
  rid := UUID_STRING();

  INSERT INTO olist_dw.audit.dq_results
    (run_id, run_at, check_name, severity, failed_rows, total_rows)
  SELECT :rid, CURRENT_TIMESTAMP(), check_name, severity, failed_rows, total_rows
  FROM (
    SELECT 'orders_pk_unique' AS check_name, 'ERROR' AS severity,
           COUNT(*) - COUNT(DISTINCT order_id) AS failed_rows, COUNT(*) AS total_rows
    FROM olist_dw.staging.orders
    UNION ALL
    SELECT 'orders_purchased_at_not_null', 'ERROR',
           COUNT_IF(purchased_at IS NULL), COUNT(*)
    FROM olist_dw.staging.orders
    UNION ALL
    SELECT 'orders_delivered_before_purchase', 'ERROR',
           COUNT_IF(delivered_at < purchased_at), COUNT(*)
    FROM olist_dw.staging.orders
    UNION ALL
    SELECT 'items_orphan_orders', 'ERROR',
           COUNT_IF(o.order_id IS NULL), COUNT(*)
    FROM olist_dw.staging.order_items i
    LEFT JOIN olist_dw.staging.orders o ON o.order_id = i.order_id
    UNION ALL
    SELECT 'items_price_positive', 'ERROR',
           COUNT_IF(price IS NULL OR price <= 0), COUNT(*)
    FROM olist_dw.staging.order_items
    UNION ALL
    SELECT 'reviews_score_in_range', 'ERROR',
           COUNT_IF(review_score IS NULL OR review_score NOT BETWEEN 1 AND 5), COUNT(*)
    FROM olist_dw.staging.order_reviews
    UNION ALL
    SELECT 'payments_value_not_negative', 'ERROR',
           COUNT_IF(payment_value IS NULL OR payment_value < 0), COUNT(*)
    FROM olist_dw.staging.order_payments
    UNION ALL
    SELECT 'fact_items_rowcount_matches_staging', 'ERROR',
           ABS((SELECT COUNT(*) FROM olist_dw.marts.fact_order_items)
             - (SELECT COUNT(*) FROM olist_dw.staging.order_items)),
           (SELECT COUNT(*) FROM olist_dw.staging.order_items)
    UNION ALL
    SELECT 'fact_revenue_matches_staging', 'ERROR',
           IFF(ABS((SELECT SUM(price) FROM olist_dw.marts.fact_order_items)
                 - (SELECT SUM(price) FROM olist_dw.staging.order_items)) > 0.01, 1, 0),
           1
    UNION ALL
    SELECT 'orders_without_items', 'WARN',
           COUNT_IF(i.order_id IS NULL), COUNT(*)
    FROM olist_dw.staging.orders o
    LEFT JOIN (SELECT DISTINCT order_id FROM olist_dw.staging.order_items) i
           ON i.order_id = o.order_id
  );

  SELECT COUNT(*) INTO :errs
  FROM olist_dw.audit.dq_results
  WHERE run_id = :rid AND severity = 'ERROR' AND failed_rows > 0;

  RETURN 'run ' || rid || ': ' || TO_VARCHAR(errs) || ' failing ERROR checks';
END;
$$;

-- Alert: logs a message if the latest DQ run has failing ERROR checks.
-- Created suspended: we trigger it by hand, so it uses no scheduled credits.
CREATE OR REPLACE ALERT olist_dw.audit.alert_dq_failures
  WAREHOUSE = wh_etl
  SCHEDULE = '60 MINUTE'
  IF (EXISTS (
        SELECT 1 FROM olist_dw.audit.v_dq_latest
        WHERE severity = 'ERROR' AND failed_rows > 0))
  THEN
    INSERT INTO olist_dw.audit.alert_log (alerted_at, message)
    SELECT CURRENT_TIMESTAMP(),
           'DQ errors: ' || LISTAGG(check_name, ', ')
    FROM olist_dw.audit.v_dq_latest
    WHERE severity = 'ERROR' AND failed_rows > 0;

-- Run 1: clean data
CALL olist_dw.audit.sp_run_dq();
SELECT check_name, severity, failed_rows, total_rows
FROM olist_dw.audit.v_dq_latest ORDER BY severity, check_name;
