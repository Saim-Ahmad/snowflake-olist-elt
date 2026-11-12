-- 03b_tasks.sql
USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;

-- Root task: loads the next batch. Created suspended. Do not resume it.
CREATE OR REPLACE TASK olist_dw.audit.t_load_batch
  WAREHOUSE = wh_etl
  SCHEDULE = '60 MINUTE'
AS
  CALL olist_dw.audit.sp_load_next_batch();

CREATE OR REPLACE TASK olist_dw.audit.t_merge_customers
  WAREHOUSE = wh_etl
  AFTER olist_dw.audit.t_load_batch
  WHEN SYSTEM$STREAM_HAS_DATA('olist_dw.raw.customers_stream')
AS
MERGE INTO olist_dw.staging.customers t
USING (
  SELECT customer_id,
         customer_unique_id,
         LPAD(customer_zip_code_prefix, 5, '0') AS zip_prefix,
         LOWER(TRIM(customer_city))             AS city,
         UPPER(TRIM(customer_state))            AS state,
         _loaded_at
  FROM olist_dw.raw.customers_stream
  QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY _loaded_at DESC) = 1
) s
ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET
  t.customer_unique_id = s.customer_unique_id, t.zip_prefix = s.zip_prefix,
  t.city = s.city, t.state = s.state, t._loaded_at = s._loaded_at
WHEN NOT MATCHED THEN INSERT (customer_id, customer_unique_id, zip_prefix, city, state, _loaded_at)
  VALUES (s.customer_id, s.customer_unique_id, s.zip_prefix, s.city, s.state, s._loaded_at);

CREATE OR REPLACE TASK olist_dw.audit.t_merge_orders
  WAREHOUSE = wh_etl
  AFTER olist_dw.audit.t_load_batch
  WHEN SYSTEM$STREAM_HAS_DATA('olist_dw.raw.orders_stream')
AS
MERGE INTO olist_dw.staging.orders t
USING (
  SELECT order_id,
         customer_id,
         LOWER(TRIM(order_status))                           AS order_status,
         TRY_TO_TIMESTAMP_NTZ(order_purchase_timestamp)      AS purchased_at,
         TRY_TO_TIMESTAMP_NTZ(order_approved_at)             AS approved_at,
         TRY_TO_TIMESTAMP_NTZ(order_delivered_carrier_date)  AS shipped_at,
         TRY_TO_TIMESTAMP_NTZ(order_delivered_customer_date) AS delivered_at,
         TRY_TO_TIMESTAMP_NTZ(order_estimated_delivery_date) AS estimated_delivery_at,
         _loaded_at
  FROM olist_dw.raw.orders_stream
  QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY _loaded_at DESC) = 1
) s
ON t.order_id = s.order_id
WHEN MATCHED THEN UPDATE SET
  t.customer_id = s.customer_id, t.order_status = s.order_status,
  t.purchased_at = s.purchased_at, t.approved_at = s.approved_at,
  t.shipped_at = s.shipped_at, t.delivered_at = s.delivered_at,
  t.estimated_delivery_at = s.estimated_delivery_at, t._loaded_at = s._loaded_at
WHEN NOT MATCHED THEN INSERT (order_id, customer_id, order_status, purchased_at, approved_at,
                              shipped_at, delivered_at, estimated_delivery_at, _loaded_at)
  VALUES (s.order_id, s.customer_id, s.order_status, s.purchased_at, s.approved_at,
          s.shipped_at, s.delivered_at, s.estimated_delivery_at, s._loaded_at);

CREATE OR REPLACE TASK olist_dw.audit.t_merge_order_items
  WAREHOUSE = wh_etl
  AFTER olist_dw.audit.t_load_batch
  WHEN SYSTEM$STREAM_HAS_DATA('olist_dw.raw.order_items_stream')
AS
MERGE INTO olist_dw.staging.order_items t
USING (
  SELECT order_id,
         TRY_TO_NUMBER(order_item_id)::INT         AS item_seq,
         product_id,
         seller_id,
         TRY_TO_TIMESTAMP_NTZ(shipping_limit_date) AS shipping_limit_at,
         TRY_TO_NUMBER(price, 10, 2)               AS price,
         TRY_TO_NUMBER(freight_value, 10, 2)       AS freight_value,
         _loaded_at
  FROM olist_dw.raw.order_items_stream
  QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id, order_item_id ORDER BY _loaded_at DESC) = 1
) s
ON t.order_id = s.order_id AND t.item_seq = s.item_seq
WHEN MATCHED THEN UPDATE SET
  t.product_id = s.product_id, t.seller_id = s.seller_id,
  t.shipping_limit_at = s.shipping_limit_at, t.price = s.price,
  t.freight_value = s.freight_value, t._loaded_at = s._loaded_at
WHEN NOT MATCHED THEN INSERT (order_id, item_seq, product_id, seller_id, shipping_limit_at,
                              price, freight_value, _loaded_at)
  VALUES (s.order_id, s.item_seq, s.product_id, s.seller_id, s.shipping_limit_at,
          s.price, s.freight_value, s._loaded_at);

CREATE OR REPLACE TASK olist_dw.audit.t_merge_order_payments
  WAREHOUSE = wh_etl
  AFTER olist_dw.audit.t_load_batch
  WHEN SYSTEM$STREAM_HAS_DATA('olist_dw.raw.order_payments_stream')
AS
MERGE INTO olist_dw.staging.order_payments t
USING (
  SELECT order_id,
         TRY_TO_NUMBER(payment_sequential)::INT   AS payment_seq,
         LOWER(TRIM(payment_type))                AS payment_type,
         TRY_TO_NUMBER(payment_installments)::INT AS installments,
         TRY_TO_NUMBER(payment_value, 10, 2)      AS payment_value,
         _loaded_at
  FROM olist_dw.raw.order_payments_stream
  QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id, payment_sequential ORDER BY _loaded_at DESC) = 1
) s
ON t.order_id = s.order_id AND t.payment_seq = s.payment_seq
WHEN MATCHED THEN UPDATE SET
  t.payment_type = s.payment_type, t.installments = s.installments,
  t.payment_value = s.payment_value, t._loaded_at = s._loaded_at
WHEN NOT MATCHED THEN INSERT (order_id, payment_seq, payment_type, installments, payment_value, _loaded_at)
  VALUES (s.order_id, s.payment_seq, s.payment_type, s.installments, s.payment_value, s._loaded_at);

CREATE OR REPLACE TASK olist_dw.audit.t_merge_order_reviews
  WAREHOUSE = wh_etl
  AFTER olist_dw.audit.t_load_batch
  WHEN SYSTEM$STREAM_HAS_DATA('olist_dw.raw.order_reviews_stream')
AS
MERGE INTO olist_dw.staging.order_reviews t
USING (
  SELECT review_id,
         order_id,
         TRY_TO_NUMBER(review_score)::INT              AS review_score,
         review_comment_title                          AS comment_title,
         review_comment_message                        AS comment_message,
         TRY_TO_TIMESTAMP_NTZ(review_creation_date)    AS created_at,
         TRY_TO_TIMESTAMP_NTZ(review_answer_timestamp) AS answered_at,
         _loaded_at
  FROM olist_dw.raw.order_reviews_stream
  QUALIFY ROW_NUMBER() OVER (
            PARTITION BY review_id
            ORDER BY TRY_TO_TIMESTAMP_NTZ(review_answer_timestamp) DESC NULLS LAST,
                     _loaded_at DESC) = 1
) s
ON t.review_id = s.review_id
WHEN MATCHED THEN UPDATE SET
  t.order_id = s.order_id, t.review_score = s.review_score,
  t.comment_title = s.comment_title, t.comment_message = s.comment_message,
  t.created_at = s.created_at, t.answered_at = s.answered_at, t._loaded_at = s._loaded_at
WHEN NOT MATCHED THEN INSERT (review_id, order_id, review_score, comment_title,
                              comment_message, created_at, answered_at, _loaded_at)
  VALUES (s.review_id, s.order_id, s.review_score, s.comment_title,
          s.comment_message, s.created_at, s.answered_at, s._loaded_at);

-- Resume the children only. The root stays suspended, so nothing runs on a schedule.
ALTER TASK olist_dw.audit.t_merge_customers      RESUME;
ALTER TASK olist_dw.audit.t_merge_orders         RESUME;
ALTER TASK olist_dw.audit.t_merge_order_items    RESUME;
ALTER TASK olist_dw.audit.t_merge_order_payments RESUME;
ALTER TASK olist_dw.audit.t_merge_order_reviews  RESUME;

-- Run the DAG once by hand
EXECUTE TASK olist_dw.audit.t_load_batch;
