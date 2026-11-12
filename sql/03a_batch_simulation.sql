-- 03a_batch_simulation.sql
USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;

-- 1. Move full transactional data into a vault; recreate empty raw tables
CREATE SCHEMA IF NOT EXISTS olist_dw.source_vault;

ALTER TABLE olist_dw.raw.customers      RENAME TO olist_dw.source_vault.customers;
ALTER TABLE olist_dw.raw.orders         RENAME TO olist_dw.source_vault.orders;
ALTER TABLE olist_dw.raw.order_items    RENAME TO olist_dw.source_vault.order_items;
ALTER TABLE olist_dw.raw.order_payments RENAME TO olist_dw.source_vault.order_payments;
ALTER TABLE olist_dw.raw.order_reviews  RENAME TO olist_dw.source_vault.order_reviews;

CREATE TABLE olist_dw.raw.customers      LIKE olist_dw.source_vault.customers;
CREATE TABLE olist_dw.raw.orders         LIKE olist_dw.source_vault.orders;
CREATE TABLE olist_dw.raw.order_items    LIKE olist_dw.source_vault.order_items;
CREATE TABLE olist_dw.raw.order_payments LIKE olist_dw.source_vault.order_payments;
CREATE TABLE olist_dw.raw.order_reviews  LIKE olist_dw.source_vault.order_reviews;

-- 2. Empty the staging copies of these tables (types stay)
TRUNCATE TABLE olist_dw.staging.customers;
TRUNCATE TABLE olist_dw.staging.orders;
TRUNCATE TABLE olist_dw.staging.order_items;
TRUNCATE TABLE olist_dw.staging.order_payments;
TRUNCATE TABLE olist_dw.staging.order_reviews;

-- 3. Batch control: one row per purchase month
CREATE OR REPLACE TABLE olist_dw.audit.batch_control AS
SELECT DATE_TRUNC('month', TRY_TO_TIMESTAMP_NTZ(order_purchase_timestamp))::DATE AS batch_month,
       'PENDING'::VARCHAR       AS status,
       NULL::INT                AS orders_loaded,
       NULL::TIMESTAMP_LTZ      AS loaded_at
FROM olist_dw.source_vault.orders
GROUP BY 1;

-- 4. Batch loader
CREATE OR REPLACE PROCEDURE olist_dw.audit.sp_load_next_batch()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  m DATE;
  tag STRING;
  n INT;
BEGIN
  SELECT MIN(batch_month) INTO :m
  FROM olist_dw.audit.batch_control WHERE status = 'PENDING';

  IF (m IS NULL) THEN
    RETURN 'no pending batches';
  END IF;

  tag := 'batch_' || TO_VARCHAR(m, 'YYYY_MM');

  INSERT INTO olist_dw.raw.orders
    SELECT * EXCLUDE (_source_file, _loaded_at), :tag, CURRENT_TIMESTAMP()
    FROM olist_dw.source_vault.orders
    WHERE DATE_TRUNC('month', TRY_TO_TIMESTAMP_NTZ(order_purchase_timestamp)) = :m;
  n := SQLROWCOUNT;

  INSERT INTO olist_dw.raw.customers
    SELECT * EXCLUDE (_source_file, _loaded_at), :tag, CURRENT_TIMESTAMP()
    FROM olist_dw.source_vault.customers
    WHERE customer_id IN (SELECT customer_id FROM olist_dw.raw.orders WHERE _source_file = :tag);

  INSERT INTO olist_dw.raw.order_items
    SELECT * EXCLUDE (_source_file, _loaded_at), :tag, CURRENT_TIMESTAMP()
    FROM olist_dw.source_vault.order_items
    WHERE order_id IN (SELECT order_id FROM olist_dw.raw.orders WHERE _source_file = :tag);

  INSERT INTO olist_dw.raw.order_payments
    SELECT * EXCLUDE (_source_file, _loaded_at), :tag, CURRENT_TIMESTAMP()
    FROM olist_dw.source_vault.order_payments
    WHERE order_id IN (SELECT order_id FROM olist_dw.raw.orders WHERE _source_file = :tag);

  INSERT INTO olist_dw.raw.order_reviews
    SELECT * EXCLUDE (_source_file, _loaded_at), :tag, CURRENT_TIMESTAMP()
    FROM olist_dw.source_vault.order_reviews
    WHERE order_id IN (SELECT order_id FROM olist_dw.raw.orders WHERE _source_file = :tag);

  UPDATE olist_dw.audit.batch_control
     SET status = 'DONE', orders_loaded = :n, loaded_at = CURRENT_TIMESTAMP()
   WHERE batch_month = :m;

  RETURN tag || ': ' || TO_VARCHAR(n) || ' orders';
END;
$$;

-- 5. Streams: record rows inserted since last consumed
CREATE OR REPLACE STREAM olist_dw.raw.customers_stream      ON TABLE olist_dw.raw.customers      APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM olist_dw.raw.orders_stream         ON TABLE olist_dw.raw.orders         APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM olist_dw.raw.order_items_stream    ON TABLE olist_dw.raw.order_items    APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM olist_dw.raw.order_payments_stream ON TABLE olist_dw.raw.order_payments APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM olist_dw.raw.order_reviews_stream  ON TABLE olist_dw.raw.order_reviews  APPEND_ONLY = TRUE;

-- 6. Test: load one batch
CALL olist_dw.audit.sp_load_next_batch();

SELECT * FROM olist_dw.audit.batch_control ORDER BY batch_month LIMIT 5;
SELECT COUNT(*) AS raw_orders      FROM olist_dw.raw.orders;
SELECT COUNT(*) AS stream_orders   FROM olist_dw.raw.orders_stream;
SELECT SYSTEM$STREAM_HAS_DATA('olist_dw.raw.orders_stream') AS has_data;
