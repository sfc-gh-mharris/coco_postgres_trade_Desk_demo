-- Stage: executor. Run as {{SERVICE_ROLE}}. Postgres login desk_exec can only list and execute
-- approved actions; it re-checks the kill switch, approval, QC verdict, expiry and idempotency.
CREATE SERVICE IF NOT EXISTS {{DB}}.APP.DESK_EXECUTOR
  IN COMPUTE POOL {{POOL}}
  EXTERNAL_ACCESS_INTEGRATIONS = ({{EAI}})
  QUERY_WAREHOUSE = {{WH}}
  MIN_INSTANCES = 1 MAX_INSTANCES = 1
  COMMENT = 'Sole executor of approved actions (simulated settlement)'
  FROM SPECIFICATION $$
spec:
  containers:
  - name: executor
    image: {{REPO_PATH}}/desk-agents:{{VERSION}}
    args: ["executor.py"]
    env:
      PGHOST: {{PG_HOST}}
      DESK_DB: {{DB}}
      SERVICE_NAME: desk_executor
      SNOWFLAKE_WAREHOUSE: {{WH}}
    secrets:
    - snowflakeSecret: {{DB}}.APP.PG_EXEC_SECRET
      directoryPath: /secrets/pg
    - snowflakeSecret: {{DB}}.APP.PG_CA_SECRET
      directoryPath: /secrets/pg_ca
    sessionTokenConfig:
      mountConnectionConfig: true
    resources:
      requests: {cpu: "0.5", memory: 1Gi}
$$;
