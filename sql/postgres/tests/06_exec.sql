-- Run as desk_exec. T-001 is APPROVED but investigator-v1 is now disabled; T-002 is AUTO_APPROVED
-- from the same disabled version, so both must be blocked.
CREATE TEMP TABLE t (name text, result text);
CREATE TEMP TABLE r AS
  SELECT a AS action_id, desk.execute_action(a, 'test-executor') AS res FROM desk.ready_actions(10) a;

INSERT INTO t SELECT 'kill_switch_blocks_approved_actions',
  CASE WHEN count(*) = 2 AND bool_and(res->>'result' = 'BLOCKED_BY_KILL_SWITCH') THEN 'PASS'
       ELSE 'FAIL ' || string_agg(res->>'result', ',') END FROM r;

DO $$ BEGIN
  PERFORM desk.claim_break('w', 'investigator-v1', 60);
  INSERT INTO t VALUES ('executor_cannot_claim', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('executor_cannot_claim', 'PASS');
END $$;

SELECT name, result FROM t ORDER BY name;
