-- Stage: agent services. Run as {{AGENT_ROLE}} (read-only in Snowflake, so an agent's SQL tool
-- cannot write anything or read ground truth). Postgres logins: desk_app (claim, heartbeat,
-- record findings, propose) and desk_qc (claim reviews, record verdicts).

CREATE SERVICE IF NOT EXISTS {{DB}}.APP.DESK_WORKER
  IN COMPUTE POOL {{POOL}}
  EXTERNAL_ACCESS_INTEGRATIONS = ({{EAI}})
  QUERY_WAREHOUSE = {{WH}}
  MIN_INSTANCES = 2 MAX_INSTANCES = 2
  COMMENT = 'Trade-break investigators (fast tier)'
  FROM SPECIFICATION $$
spec:
  containers:
  - name: worker
    image: {{REPO_PATH}}/desk-agents:{{VERSION}}
    args: ["worker.py"]
    env:
      PGHOST: {{PG_HOST}}
      DESK_DB: {{DB}}
      AGENT_VERSION: investigator-v1
      WORKER_CONCURRENCY: "2"
      SERVICE_NAME: desk_worker
      SNOWFLAKE_WAREHOUSE: {{WH}}
    secrets:
    - snowflakeSecret: {{DB}}.APP.PG_DESK_SECRET
      directoryPath: /secrets/pg
    - snowflakeSecret: {{DB}}.APP.PG_CA_SECRET
      directoryPath: /secrets/pg_ca
    sessionTokenConfig:
      mountConnectionConfig: true
    resources:
      requests: {cpu: "1", memory: 2Gi}
      limits: {cpu: "2", memory: 4Gi}
$$;

-- Canary: investigator-v3 with a loosened cash rule (staged regression), disabled by default.
CREATE SERVICE IF NOT EXISTS {{DB}}.APP.DESK_WORKER_CANARY
  IN COMPUTE POOL {{POOL}}
  EXTERNAL_ACCESS_INTEGRATIONS = ({{EAI}})
  QUERY_WAREHOUSE = {{WH}}
  MIN_INSTANCES = 1 MAX_INSTANCES = 1
  COMMENT = 'Canary investigator: prompt inv-p3-loose (staged regression); disabled in agent_controls by default'
  FROM SPECIFICATION $$
spec:
  containers:
  - name: worker
    image: {{REPO_PATH}}/desk-agents:{{VERSION}}
    args: ["worker.py"]
    env:
      PGHOST: {{PG_HOST}}
      DESK_DB: {{DB}}
      AGENT_VERSION: investigator-v3
      WORKER_CONCURRENCY: "2"
      SERVICE_NAME: desk_canary
      SNOWFLAKE_WAREHOUSE: {{WH}}
    secrets:
    - snowflakeSecret: {{DB}}.APP.PG_DESK_SECRET
      directoryPath: /secrets/pg
    - snowflakeSecret: {{DB}}.APP.PG_CA_SECRET
      directoryPath: /secrets/pg_ca
    sessionTokenConfig:
      mountConnectionConfig: true
    resources:
      requests: {cpu: "1", memory: 2Gi}
      limits: {cpu: "2", memory: 4Gi}
$$;

CREATE SERVICE IF NOT EXISTS {{DB}}.APP.DESK_QC
  IN COMPUTE POOL {{POOL}}
  EXTERNAL_ACCESS_INTEGRATIONS = ({{EAI}})
  QUERY_WAREHOUSE = {{WH}}
  MIN_INSTANCES = 1 MAX_INSTANCES = 1
  COMMENT = 'Independent QC reviewer (capable tier)'
  FROM SPECIFICATION $$
spec:
  containers:
  - name: qc
    image: {{REPO_PATH}}/desk-agents:{{VERSION}}
    args: ["qc.py"]
    env:
      PGHOST: {{PG_HOST}}
      DESK_DB: {{DB}}
      AGENT_VERSION: qc-v1
      SERVICE_NAME: desk_qc
      SNOWFLAKE_WAREHOUSE: {{WH}}
    secrets:
    - snowflakeSecret: {{DB}}.APP.PG_QC_SECRET
      directoryPath: /secrets/pg
    - snowflakeSecret: {{DB}}.APP.PG_CA_SECRET
      directoryPath: /secrets/pg_ca
    sessionTokenConfig:
      mountConnectionConfig: true
    resources:
      requests: {cpu: "1", memory: 2Gi}
      limits: {cpu: "2", memory: 4Gi}
$$;
