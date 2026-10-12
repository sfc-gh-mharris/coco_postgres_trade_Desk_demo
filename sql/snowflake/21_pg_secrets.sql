-- Stage: Postgres secrets. Run as ACCOUNTADMIN after PG_ADMIN_SECRET and PG_CA_SECRET exist.
-- Generates random passwords for the five least-privilege desk logins straight into secrets
-- (the values never leave Snowflake), then grants each owner role only what its containers mount.

EXECUTE IMMEDIATE $$
DECLARE
  users ARRAY := ARRAY_CONSTRUCT('desk_app', 'desk_qc', 'desk_exec', 'desk_approver_svc', 'desk_sim');
  secrets ARRAY := ARRAY_CONSTRUCT('PG_DESK_SECRET', 'PG_QC_SECRET', 'PG_EXEC_SECRET', 'PG_APPROVER_SECRET', 'PG_SIM_SECRET');
  i INTEGER DEFAULT 0;
  pw STRING;
BEGIN
  FOR i IN 0 TO ARRAY_SIZE(:users) - 1 DO
    pw := RANDSTR(40, RANDOM());
    EXECUTE IMMEDIATE 'CREATE SECRET IF NOT EXISTS {{DB}}.APP.' || GET(:secrets, :i)::STRING ||
      ' TYPE = PASSWORD USERNAME = ''' || GET(:users, :i)::STRING || ''' PASSWORD = ''' || :pw || '''';
  END FOR;
  RETURN 'desk secrets ready';
END;
$$;

-- Jobs (schema, tests, simulator) run as the service role and need every login.
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_ADMIN_SECRET TO ROLE {{SERVICE_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_DESK_SECRET TO ROLE {{SERVICE_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_QC_SECRET TO ROLE {{SERVICE_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_EXEC_SECRET TO ROLE {{SERVICE_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_APPROVER_SECRET TO ROLE {{SERVICE_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_SIM_SECRET TO ROLE {{SERVICE_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_CA_SECRET TO ROLE {{SERVICE_ROLE}};
-- Agents: investigator and QC logins only.
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_DESK_SECRET TO ROLE {{AGENT_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_QC_SECRET TO ROLE {{AGENT_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_CA_SECRET TO ROLE {{AGENT_ROLE}};
-- Node command center: approver and simulator logins only.
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_APPROVER_SECRET TO ROLE {{COMMAND_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_SIM_SECRET TO ROLE {{COMMAND_ROLE}};
GRANT READ, USAGE ON SECRET {{DB}}.APP.PG_CA_SECRET TO ROLE {{COMMAND_ROLE}};
