-- Additions for the DESK_COMMAND app: desk days, end-of-day close, agent activity view.
-- Additive and idempotent: safe to re-run on top of desk_schema.sql without losing demo data.
-- Applied from SPCS by scripts/pg_run.sh as snowflake_admin.

SET ROLE desk_owner;
SET search_path = desk, pg_catalog;

-- ---------------------------------------------------------------- desk days

CREATE TABLE IF NOT EXISTS desk.desk_days (
  day_id          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  opened_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
  opened_by       text NOT NULL,
  closed_summary  jsonb                       -- summary of the close that ended the PREVIOUS day
);
INSERT INTO desk.desk_days (opened_at, opened_by)
SELECT COALESCE((SELECT min(created_at) FROM desk.breaks), now()), 'bootstrap'
 WHERE NOT EXISTS (SELECT 1 FROM desk.desk_days);

-- Close the current desk day: work still open is carried to the exceptions queue (ESCALATED) and
-- open actions expire. Nothing is deleted. Setting breaks out of CLAIMED fences in-flight agents:
-- record_finding / propose_action require status = 'CLAIMED' with a matching fence token.
CREATE OR REPLACE FUNCTION desk.close_desk_day(p_actor text, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
DECLARE
  v_fenced  int;
  v_actions int;
  v_breaks  int;
  v_summary jsonb;
  v_day     int;
BEGIN
  IF p_actor IS NULL OR length(trim(p_actor)) = 0 THEN
    RAISE EXCEPTION 'actor identity is required';
  END IF;

  SELECT count(*) INTO v_fenced FROM desk.breaks WHERE status = 'CLAIMED';

  WITH expired AS (
    UPDATE desk.proposed_actions
       SET status = 'EXPIRED', qc_lease_owner = NULL, qc_lease_expires_at = NULL, updated_at = now()
     WHERE status IN ('PENDING_QC', 'QC_HOLD', 'PENDING_APPROVAL')
        OR (status IN ('APPROVED', 'AUTO_APPROVED') AND executed_at IS NULL)
     RETURNING action_id, break_id, proposed_by_version, status
  )
  INSERT INTO desk.desk_events (break_id, action_id, actor_type, actor_id, event_type, agent_version, payload)
  SELECT break_id, action_id, 'human', p_actor, 'ACTION_EXPIRED_EOD', proposed_by_version,
         jsonb_build_object('note', p_note)
    FROM expired;
  GET DIAGNOSTICS v_actions = ROW_COUNT;

  WITH carried AS (
    UPDATE desk.breaks
       SET status = 'ESCALATED', lease_owner = NULL, lease_expires_at = NULL,
           fence_token = fence_token + 1, updated_at = now()
     WHERE status IN ('NEW', 'CLAIMED', 'PROPOSED', 'REOPENED')
     RETURNING break_id, fence_token
  )
  INSERT INTO desk.desk_events (break_id, actor_type, actor_id, event_type, payload)
  SELECT break_id, 'human', p_actor, 'DAY_CLOSED', jsonb_build_object('fence_token', fence_token, 'note', p_note)
    FROM carried;
  GET DIAGNOSTICS v_breaks = ROW_COUNT;

  v_summary := jsonb_build_object('breaks_carried', v_breaks, 'actions_expired', v_actions,
                                  'leases_fenced', v_fenced, 'closed_by', p_actor, 'note', p_note,
                                  'closed_at', clock_timestamp());
  INSERT INTO desk.desk_days (opened_by, closed_summary) VALUES (p_actor, v_summary)
  RETURNING day_id INTO v_day;
  v_summary := v_summary || jsonb_build_object('new_day_id', v_day);

  PERFORM desk.log_event(NULL, NULL, NULL, 'human', p_actor, 'DESK_DAY_OPENED', NULL, NULL, v_summary);
  PERFORM pg_notify('desk_day', v_day::text);
  RETURN v_summary;
END $$;

-- ---------------------------------------------------------------- agent activity

-- One row per agent slot seen in the last hour plus any in-flight claim (investigator or QC).
CREATE OR REPLACE VIEW desk.v_agent_activity AS
  WITH slots AS (
    SELECT worker_id, agent_role, agent_version, model,
           count(*) FILTER (WHERE ended_at > now() - interval '10 minutes') AS runs_10m,
           count(*) AS runs_1h,
           max(ended_at) AS last_run_at,
           round(avg(llm_ms)) AS avg_llm_ms
      FROM desk.agent_runs
     WHERE ended_at > now() - interval '1 hour'
     GROUP BY worker_id, agent_role, agent_version, model
  ),
  busy AS (
    SELECT lease_owner AS worker_id, 'investigator'::text AS agent_role, claimed_version AS agent_version,
           break_id, NULL::bigint AS action_id, updated_at AS busy_since, lease_expires_at
      FROM desk.breaks WHERE status = 'CLAIMED' AND lease_owner IS NOT NULL
    UNION ALL
    SELECT qc_lease_owner, 'qc', NULL, break_id, action_id, updated_at, qc_lease_expires_at
      FROM desk.proposed_actions
     WHERE qc_lease_owner IS NOT NULL AND qc_lease_expires_at > now()
       AND qc_status IN ('PENDING', 'SAMPLE_PENDING')
  )
  SELECT COALESCE(s.worker_id, b.worker_id)         AS worker_id,
         COALESCE(s.agent_role, b.agent_role)       AS agent_role,
         COALESCE(b.agent_version, s.agent_version) AS agent_version,
         s.model, COALESCE(s.runs_10m, 0) AS runs_10m, COALESCE(s.runs_1h, 0) AS runs_1h,
         s.last_run_at, s.avg_llm_ms,
         b.break_id AS busy_break_id, b.action_id AS busy_action_id, b.busy_since, b.lease_expires_at,
         (b.worker_id IS NOT NULL) AS busy
    FROM slots s FULL OUTER JOIN busy b ON b.worker_id = s.worker_id AND b.agent_role = s.agent_role;

-- Latest receipt-to-claim latency (the LISTEN/NOTIFY wake-up), last 50 claims.
CREATE OR REPLACE VIEW desk.v_wakeup_latency AS
  SELECT c.break_id, c.actor_id AS worker_id, c.occurred_at AS claimed_at,
         round(extract(epoch FROM (c.occurred_at - r.occurred_at)) * 1000) AS wake_ms
    FROM desk.desk_events c
    JOIN desk.desk_events r ON r.break_id = c.break_id AND r.event_type = 'BREAK_RECEIVED'
   WHERE c.event_type = 'CLAIMED'
   ORDER BY c.event_id DESC LIMIT 50;

CREATE OR REPLACE VIEW desk.v_current_day AS
  SELECT day_id, opened_at, opened_by, closed_summary FROM desk.desk_days ORDER BY day_id DESC LIMIT 1;

-- ---------------------------------------------------------------- privileges

RESET ROLE;
REVOKE ALL ON FUNCTION desk.close_desk_day(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION desk.close_desk_day(text, text) TO desk_approver_svc;
GRANT SELECT ON desk.v_agent_activity, desk.v_wakeup_latency, desk.v_current_day, desk.desk_days
      TO desk_approver_svc;
GRANT SELECT ON desk.desk_days TO snowflake_read_only;

SELECT 'SQLRUN desk_command applied' AS status,
       (SELECT count(*) FROM desk.desk_days) AS desk_days,
       (SELECT count(*) FROM desk.v_agent_activity) AS activity_rows;
