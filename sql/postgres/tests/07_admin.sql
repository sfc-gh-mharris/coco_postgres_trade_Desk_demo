-- Run as snowflake_admin: ledger immutability, idempotent re-execution, event trail, and reset.
CREATE TEMP TABLE t (name text, result text);

DO $$ BEGIN
  UPDATE desk.desk_events SET actor_id = 'tampered' WHERE event_id = 1;
  INSERT INTO t VALUES ('events_update_blocked', 'FAIL');
EXCEPTION WHEN raise_exception THEN INSERT INTO t VALUES ('events_update_blocked', 'PASS');
END $$;

DO $$ BEGIN
  DELETE FROM desk.desk_events WHERE event_id = 1;
  INSERT INTO t VALUES ('events_delete_blocked', 'FAIL');
EXCEPTION WHEN raise_exception THEN INSERT INTO t VALUES ('events_delete_blocked', 'PASS');
END $$;

DO $$ BEGIN
  TRUNCATE desk.desk_events;
  INSERT INTO t VALUES ('events_truncate_blocked', 'FAIL');
EXCEPTION WHEN raise_exception THEN INSERT INTO t VALUES ('events_truncate_blocked', 'PASS');
END $$;

-- re-enable v1, re-approve path is not allowed from BLOCKED; executing again must be a no-op
INSERT INTO t SELECT 'blocked_action_stays_blocked',
  CASE WHEN desk.execute_action(action_id, 'test-executor')->>'result' = 'NOT_EXECUTABLE' THEN 'PASS' ELSE 'FAIL' END
  FROM desk.proposed_actions WHERE break_id = 'T-001';

INSERT INTO t SELECT 'event_trail_complete',
  CASE WHEN array_agg(event_type ORDER BY event_id) @> ARRAY['BREAK_RECEIVED', 'CLAIMED', 'ACTION_PROPOSED',
       'QC_CLAIMED', 'QC_REVIEWED', 'APPROVAL_HASH_MISMATCH', 'ACTION_APPROVED', 'BLOCKED_BY_KILL_SWITCH']
       THEN 'PASS' ELSE 'FAIL ' || array_to_string(array_agg(event_type ORDER BY event_id), ',') END
  FROM desk.desk_events WHERE break_id = 'T-001';

SELECT name, result FROM t ORDER BY name;
