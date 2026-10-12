-- Stage: Streamlit approval console. Run as {{SERVICE_ROLE}}. Postgres login desk_approver_svc can
-- only approve/reject (hash-bound) and flip the kill switch; the approver identity comes from the
-- Sf-Context-Current-User header set by the SPCS ingress.
CREATE SERVICE IF NOT EXISTS {{DB}}.APP.DESK_CONSOLE
  IN COMPUTE POOL {{POOL}}
  EXTERNAL_ACCESS_INTEGRATIONS = ({{EAI}})
  MIN_INSTANCES = 1 MAX_INSTANCES = 1
  COMMENT = 'Human approval console (Streamlit)'
  FROM SPECIFICATION $$
spec:
  containers:
  - name: console
    image: {{REPO_PATH}}/desk-agents:{{VERSION}}
    command: ["streamlit", "run", "/app/console.py", "--server.port=8501", "--server.address=0.0.0.0",
              "--server.headless=true", "--browser.gatherUsageStats=false"]
    env:
      PGHOST: {{PG_HOST}}
      DESK_DB: {{DB}}
      SERVICE_NAME: desk_console
    secrets:
    - snowflakeSecret: {{DB}}.APP.PG_APPROVER_SECRET
      directoryPath: /secrets/pg
    - snowflakeSecret: {{DB}}.APP.PG_CA_SECRET
      directoryPath: /secrets/pg_ca
    readinessProbe:
      port: 8501
      path: /_stcore/health
  endpoints:
  - name: console
    port: 8501
    public: true
serviceRoles:
- name: approver
  endpoints:
  - console
$$;

GRANT SERVICE ROLE {{DB}}.APP.DESK_CONSOLE!APPROVER TO ROLE {{APPROVER_ROLE}};
