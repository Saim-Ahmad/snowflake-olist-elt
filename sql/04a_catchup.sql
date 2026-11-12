-- 04a_catchup.sql
USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;

EXECUTE IMMEDIATE $$
DECLARE
  r STRING DEFAULT 'start';
BEGIN
  WHILE (r <> 'no pending batches') DO
    CALL olist_dw.audit.sp_load_next_batch() INTO :r;
  END WHILE;
  RETURN r;
END;
$$;

EXECUTE TASK olist_dw.audit.t_load_batch;

--wait for some time before executing from here onwards
USE ROLE SYSADMIN;
USE WAREHOUSE wh_etl;

SELECT 'orders' AS tbl,
       (SELECT COUNT(*) FROM olist_dw.staging.orders) AS n,
       (SELECT COUNT(*) FROM olist_dw.source_vault.orders) AS expected
UNION ALL SELECT 'customers',
       (SELECT COUNT(*) FROM olist_dw.staging.customers),
       (SELECT COUNT(*) FROM olist_dw.source_vault.customers)
UNION ALL SELECT 'order_items',
       (SELECT COUNT(*) FROM olist_dw.staging.order_items),
       (SELECT COUNT(*) FROM olist_dw.source_vault.order_items)
UNION ALL SELECT 'order_payments',
       (SELECT COUNT(*) FROM olist_dw.staging.order_payments),
       (SELECT COUNT(*) FROM olist_dw.source_vault.order_payments)
UNION ALL SELECT 'order_reviews (deduped)',
       (SELECT COUNT(*) FROM olist_dw.staging.order_reviews),
       (SELECT COUNT(DISTINCT review_id) FROM olist_dw.source_vault.order_reviews);

SELECT status, COUNT(*) FROM olist_dw.audit.batch_control GROUP BY status;  -- expect only DONE
SELECT SYSTEM$STREAM_HAS_DATA('olist_dw.raw.orders_stream') AS stream_has_data;  -- expect FALSE
