-- 02_staging.sql
USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;
USE SCHEMA olist_dw.staging;

CREATE OR REPLACE TABLE customers AS
SELECT customer_id,
       customer_unique_id,
       LPAD(customer_zip_code_prefix, 5, '0') AS zip_prefix,
       LOWER(TRIM(customer_city))             AS city,
       UPPER(TRIM(customer_state))            AS state,
       _loaded_at
FROM olist_dw.raw.customers;

CREATE OR REPLACE TABLE sellers AS
SELECT seller_id,
       LPAD(seller_zip_code_prefix, 5, '0') AS zip_prefix,
       LOWER(TRIM(seller_city))             AS city,
       UPPER(TRIM(seller_state))            AS state,
       _loaded_at
FROM olist_dw.raw.sellers;

CREATE OR REPLACE TABLE geolocation_zip AS
SELECT LPAD(geolocation_zip_code_prefix, 5, '0') AS zip_prefix,
       AVG(TRY_TO_DOUBLE(geolocation_lat))       AS lat,
       AVG(TRY_TO_DOUBLE(geolocation_lng))       AS lng
FROM olist_dw.raw.geolocation
GROUP BY 1;

CREATE OR REPLACE TABLE orders AS
SELECT order_id,
       customer_id,
       LOWER(TRIM(order_status))                          AS order_status,
       TRY_TO_TIMESTAMP_NTZ(order_purchase_timestamp)     AS purchased_at,
       TRY_TO_TIMESTAMP_NTZ(order_approved_at)            AS approved_at,
       TRY_TO_TIMESTAMP_NTZ(order_delivered_carrier_date) AS shipped_at,
       TRY_TO_TIMESTAMP_NTZ(order_delivered_customer_date) AS delivered_at,
       TRY_TO_TIMESTAMP_NTZ(order_estimated_delivery_date) AS estimated_delivery_at,
       _loaded_at
FROM olist_dw.raw.orders;

CREATE OR REPLACE TABLE order_items AS
SELECT order_id,
       TRY_TO_NUMBER(order_item_id)::INT          AS item_seq,
       product_id,
       seller_id,
       TRY_TO_TIMESTAMP_NTZ(shipping_limit_date)  AS shipping_limit_at,
       TRY_TO_NUMBER(price, 10, 2)                AS price,
       TRY_TO_NUMBER(freight_value, 10, 2)        AS freight_value,
       _loaded_at
FROM olist_dw.raw.order_items;

CREATE OR REPLACE TABLE order_payments AS
SELECT order_id,
       TRY_TO_NUMBER(payment_sequential)::INT     AS payment_seq,
       LOWER(TRIM(payment_type))                  AS payment_type,
       TRY_TO_NUMBER(payment_installments)::INT   AS installments,
       TRY_TO_NUMBER(payment_value, 10, 2)        AS payment_value,
       _loaded_at
FROM olist_dw.raw.order_payments;

CREATE OR REPLACE TABLE order_reviews AS
SELECT review_id,
       order_id,
       TRY_TO_NUMBER(review_score)::INT               AS review_score,
       review_comment_title                           AS comment_title,
       review_comment_message                         AS comment_message,
       TRY_TO_TIMESTAMP_NTZ(review_creation_date)     AS created_at,
       TRY_TO_TIMESTAMP_NTZ(review_answer_timestamp)  AS answered_at,
       _loaded_at
FROM olist_dw.raw.order_reviews
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY review_id
          ORDER BY TRY_TO_TIMESTAMP_NTZ(review_answer_timestamp) DESC NULLS LAST) = 1;

CREATE OR REPLACE TABLE products AS
SELECT p.product_id,
       COALESCE(p.product_category_name, 'unknown')  AS category_pt,
       COALESCE(t.product_category_name_english,
                p.product_category_name, 'unknown')  AS category_en,
       TRY_TO_NUMBER(p.product_name_lenght)::INT        AS name_length,
       TRY_TO_NUMBER(p.product_description_lenght)::INT AS description_length,
       TRY_TO_NUMBER(p.product_photos_qty)::INT         AS photos_qty,
       TRY_TO_NUMBER(p.product_weight_g)::INT           AS weight_g,
       TRY_TO_NUMBER(p.product_length_cm)::INT          AS length_cm,
       TRY_TO_NUMBER(p.product_height_cm)::INT          AS height_cm,
       TRY_TO_NUMBER(p.product_width_cm)::INT           AS width_cm,
       p._loaded_at
FROM olist_dw.raw.products p
LEFT JOIN olist_dw.raw.category_translation t
       ON p.product_category_name = t.product_category_name;

-- Verify 1: row counts
SELECT 'customers' AS tbl, COUNT(*) AS n FROM customers
UNION ALL SELECT 'sellers',         COUNT(*) FROM sellers
UNION ALL SELECT 'geolocation_zip', COUNT(*) FROM geolocation_zip
UNION ALL SELECT 'orders',          COUNT(*) FROM orders
UNION ALL SELECT 'order_items',     COUNT(*) FROM order_items
UNION ALL SELECT 'order_payments',  COUNT(*) FROM order_payments
UNION ALL SELECT 'order_reviews',   COUNT(*) FROM order_reviews
UNION ALL SELECT 'products',        COUNT(*) FROM products;

-- Verify 2: casts that silently became NULL (all should be 0)
SELECT 'orders.purchased_at' AS col, COUNT(*) AS bad
FROM olist_dw.raw.orders
WHERE order_purchase_timestamp IS NOT NULL
  AND TRY_TO_TIMESTAMP_NTZ(order_purchase_timestamp) IS NULL
UNION ALL
SELECT 'order_items.price', COUNT(*)
FROM olist_dw.raw.order_items
WHERE price IS NOT NULL AND TRY_TO_NUMBER(price, 10, 2) IS NULL
UNION ALL
SELECT 'order_payments.payment_value', COUNT(*)
FROM olist_dw.raw.order_payments
WHERE payment_value IS NOT NULL AND TRY_TO_NUMBER(payment_value, 10, 2) IS NULL
UNION ALL
SELECT 'order_reviews.review_score', COUNT(*)
FROM olist_dw.raw.order_reviews
WHERE review_score IS NOT NULL AND TRY_TO_NUMBER(review_score) IS NULL;
