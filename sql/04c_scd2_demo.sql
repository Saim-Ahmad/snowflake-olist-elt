-- 04c_scd2_demo.sql
USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;

SET pid = (SELECT MIN(product_id) FROM olist_dw.staging.products WHERE category_en = 'toys');

-- Before: expect 1 row, valid_from 1900-01-01, is_current TRUE
SELECT product_key, category_en, valid_from, valid_to, is_current
FROM olist_dw.marts.dim_product WHERE product_id = $pid ORDER BY valid_from;

-- Simulate a source change, then reload the dimension
UPDATE olist_dw.staging.products SET category_en = 'toys_and_games' WHERE product_id = $pid;
CALL olist_dw.marts.sp_load_dim_product();   -- expect: closed 1, inserted 1

-- After: expect 2 rows (old closed, new current)
SELECT product_key, category_en, valid_from, valid_to, is_current
FROM olist_dw.marts.dim_product WHERE product_id = $pid ORDER BY valid_from;

-- History preserved: 2017-2018 orders still resolve to the OLD version
SELECT p.product_key, p.category_en, p.is_current, COUNT(*) AS order_items
FROM olist_dw.marts.fact_order_items f
JOIN olist_dw.marts.dim_product p
  ON p.product_id = f.product_id
 AND f.purchased_at >= p.valid_from
 AND f.purchased_at <  p.valid_to
WHERE f.product_id = $pid
GROUP BY 1, 2, 3;

-- Revert the source change (this adds a third version, which is fine)
UPDATE olist_dw.staging.products SET category_en = 'toys' WHERE product_id = $pid;
CALL olist_dw.marts.sp_load_dim_product();
