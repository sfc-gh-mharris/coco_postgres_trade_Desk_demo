-- Run as desk_approver_svc after QC concurred on T-001.
CREATE TEMP TABLE t (name text, result text);

INSERT INTO t
SELECT 'hash_mismatch_rejected_and_logged',
       CASE WHEN desk.approve_action(action_id, 'deadbeef', 'tester', 'APPROVE') = 'HASH_MISMATCH'
            THEN 'PASS' ELSE 'FAIL' END
  FROM desk.v_pending_actions WHERE break_id = 'T-001';

INSERT INTO t
SELECT 'approve_after_qc_concur',
       CASE WHEN desk.approve_action(action_id, payload_sha256, 'tester@snowflake', 'APPROVE', 'test') = 'APPROVED'
            THEN 'PASS' ELSE 'FAIL' END
  FROM desk.v_pending_actions WHERE break_id = 'T-001';

-- kill switch: disable the version that proposed the now-approved action
INSERT INTO t SELECT 'kill_switch_set',
  CASE WHEN desk.set_agent_control('investigator-v1', false, 'tester@snowflake') = false THEN 'PASS' ELSE 'FAIL' END;

SELECT name, result FROM t ORDER BY name;
