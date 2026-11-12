-- 01_raw_load.sql (pilot: customers)
USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;
USE SCHEMA olist_dw.raw;

-- 1. Create the table from the CSV header, every column as TEXT.
--    UPPER() makes the column names unquoted-friendly.
CREATE OR REPLACE TABLE customers USING TEMPLATE (
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
           'COLUMN_NAME', UPPER(COLUMN_NAME),
           'TYPE', 'TEXT',
           'NULLABLE', TRUE,
           'ORDER_ID', ORDER_ID))
         WITHIN GROUP (ORDER BY ORDER_ID)
  FROM TABLE(INFER_SCHEMA(
         LOCATION => '@olist_dw.raw.stg_olist',
         FILES => 'olist_customers_dataset.csv',
         FILE_FORMAT => 'olist_dw.raw.ff_csv')));

-- 2. Lineage columns
ALTER TABLE customers ADD COLUMN _source_file VARCHAR;
ALTER TABLE customers ADD COLUMN _loaded_at TIMESTAMP_LTZ;

-- 3. Load
USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;
USE SCHEMA olist_dw.raw;

ALTER FILE FORMAT olist_dw.raw.ff_csv SET ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

COPY INTO customers
FROM @olist_dw.raw.stg_olist/olist_customers_dataset.csv
FILE_FORMAT = (FORMAT_NAME = 'olist_dw.raw.ff_csv')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (_source_file = METADATA$FILENAME,
                    _loaded_at = METADATA$START_SCAN_TIME);



-- 4. Verify
DESC TABLE customers;
SELECT COUNT(*) FROM customers;          -- expect 99441
SELECT * FROM customers LIMIT 5;


EXECUTE IMMEDIATE $$
DECLARE
  c CURSOR FOR
    SELECT tbl, f FROM (VALUES
      ('customers',      'olist_customers_dataset.csv'),
      ('geolocation',    'olist_geolocation_dataset.csv'),
      ('order_items',    'olist_order_items_dataset.csv'),
      ('order_payments', 'olist_order_payments_dataset.csv'),
      ('order_reviews',  'olist_order_reviews_dataset.csv'),
      ('orders',         'olist_orders_dataset.csv'),
      ('products',       'olist_products_dataset.csv'),
      ('sellers',        'olist_sellers_dataset.csv'),
      ('category_translation', 'product_category_name_translation.csv')
    ) AS t(tbl, f);
BEGIN
  FOR r IN c DO
    LET s1 STRING := 'CREATE OR REPLACE TABLE olist_dw.raw.' || r.tbl ||
      ' USING TEMPLATE (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(''COLUMN_NAME'', UPPER(COLUMN_NAME), ''TYPE'', ''TEXT'', ''NULLABLE'', TRUE, ''ORDER_ID'', ORDER_ID)) WITHIN GROUP (ORDER BY ORDER_ID) FROM TABLE(INFER_SCHEMA(LOCATION => ''@olist_dw.raw.stg_olist'', FILES => ''' || r.f || ''', FILE_FORMAT => ''olist_dw.raw.ff_csv'')))';
    EXECUTE IMMEDIATE :s1;

    LET s2 STRING := 'ALTER TABLE olist_dw.raw.' || r.tbl || ' ADD COLUMN _source_file VARCHAR';
    EXECUTE IMMEDIATE :s2;
    LET s3 STRING := 'ALTER TABLE olist_dw.raw.' || r.tbl || ' ADD COLUMN _loaded_at TIMESTAMP_LTZ';
    EXECUTE IMMEDIATE :s3;

    LET s4 STRING := 'COPY INTO olist_dw.raw.' || r.tbl ||
      ' FROM @olist_dw.raw.stg_olist/' || r.f ||
      ' FILE_FORMAT = (FORMAT_NAME = ''olist_dw.raw.ff_csv'')' ||
      ' MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE' ||
      ' INCLUDE_METADATA = (_source_file = METADATA$FILENAME, _loaded_at = METADATA$START_SCAN_TIME)';
    EXECUTE IMMEDIATE :s4;
  END FOR;
  RETURN 'done';
END;
$$;

-- Verify
SELECT 'customers' AS tbl, COUNT(*) AS n, 99441 AS expected FROM customers
UNION ALL SELECT 'geolocation',          COUNT(*), 1000163 FROM geolocation
UNION ALL SELECT 'order_items',          COUNT(*), 112650  FROM order_items
UNION ALL SELECT 'order_payments',       COUNT(*), 103886  FROM order_payments
UNION ALL SELECT 'order_reviews',        COUNT(*), 99224   FROM order_reviews
UNION ALL SELECT 'orders',               COUNT(*), 99441   FROM orders
UNION ALL SELECT 'products',             COUNT(*), 32951   FROM products
UNION ALL SELECT 'sellers',              COUNT(*), 3095    FROM sellers
UNION ALL SELECT 'category_translation', COUNT(*), 71      FROM category_translation;
