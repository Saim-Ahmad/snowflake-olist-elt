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
