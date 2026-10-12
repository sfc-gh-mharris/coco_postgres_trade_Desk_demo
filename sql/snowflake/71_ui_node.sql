-- Stage: Node command center (live approvals + mirror dashboard). Run as {{COMMAND_ROLE}}.
-- Postgres logins: desk_approver_svc (approve, kill switch, close day) and desk_sim (insert breaks).
CREATE SERVICE IF NOT EXISTS {{DB}}.APP.DESK_COMMAND
  IN COMPUTE POOL {{POOL}}
  EXTERNAL_ACCESS_INTEGRATIONS = ({{EAI}})
  QUERY_WAREHOUSE = {{WH}}
  MIN_INSTANCES = 1 MAX_INSTANCES = 1
  COMMENT = 'Break desk command center: live approvals + mirror dashboard (Node)'
  FROM SPECIFICATION $$
spec:
  containers:
  - name: command
    image: {{REPO_PATH}}/desk-command:{{VERSION}}
    env:
      PGHOST: {{PG_HOST}}
      DESK_DB: {{DB}}
      MIRROR_DB: {{MIRROR_DB}}
      SNOWFLAKE_WAREHOUSE: {{WH}}
      PORT: "8080"
    secrets:
    - snowflakeSecret: {{DB}}.APP.PG_APPROVER_SECRET
      directoryPath: /secrets/pg_approver
    - snowflakeSecret: {{DB}}.APP.PG_SIM_SECRET
      directoryPath: /secrets/pg_sim
    - snowflakeSecret: {{DB}}.APP.PG_CA_SECRET
      directoryPath: /secrets/pg_ca
    readinessProbe:
      port: 8080
      path: /api/health
    resources:
      requests: {cpu: "0.5", memory: 512Mi}
  endpoints:
  - name: command
    port: 8080
    public: true
serviceRoles:
- name: approver
  endpoints:
  - command
$$;

GRANT SERVICE ROLE {{DB}}.APP.DESK_COMMAND!APPROVER TO ROLE {{APPROVER_ROLE}};
