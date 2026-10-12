-- Stage: Postgres admin secret (PG_MODE=create only). Run as ACCOUNTADMIN once the instance is READY.
-- Rotates the snowflake_admin password and writes it straight into PG_ADMIN_SECRET. The password
-- is read from RESULT_SCAN inside this block and never returned, printed, or written to disk.
-- Re-running rotates the password again and replaces the secret, which is safe for this demo.
EXECUTE IMMEDIATE $$
DECLARE
  pw STRING;
BEGIN
  ALTER POSTGRES INSTANCE "{{PG_INSTANCE}}" RESET ACCESS FOR 'snowflake_admin';
  SELECT $1 INTO :pw FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
  IF (:pw IS NULL OR LENGTH(:pw) < 8) THEN
    RETURN 'ERROR: RESET ACCESS returned no password';
  END IF;
  EXECUTE IMMEDIATE 'CREATE OR REPLACE SECRET {{DB}}.APP.PG_ADMIN_SECRET TYPE = PASSWORD USERNAME = ''snowflake_admin'' PASSWORD = '''
    || REPLACE(REPLACE(:pw, '\\', '\\\\'), '''', '\\''') || '''';
  RETURN 'admin secret ready';
END;
$$;
