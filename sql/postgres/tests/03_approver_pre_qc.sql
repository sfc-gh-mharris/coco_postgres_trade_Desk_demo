-- Run as desk_approver_svc. T-001 (tier-2 cash) is still PENDING_QC.
CREATE TEMP TABLE t (name text, result text);

DO $$ DECLARE v_id bigint; v_hash text; BEGIN
  SELECT action_id, payload_sha256 INTO v_id, v_hash FROM desk.v_pending_actions WHERE break_id = 'T-001';
  PERFORM desk.approve_action(v_id, v_hash, 'tester', 'APPROVE');
  INSERT INTO t VALUES ('tier2_needs_qc_before_approval', 'FAIL');
EXCEPTION WHEN raise_exception THEN INSERT INTO t VALUES ('tier2_needs_qc_before_approval', 'PASS');
END $$;

DO $$ BEGIN
  PERFORM desk.execute_action(1, 'approver');
  INSERT INTO t VALUES ('approver_cannot_execute', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('approver_cannot_execute', 'PASS');
END $$;

DO $$ BEGIN
  PERFORM desk.approve_action(1, 'x', '', 'APPROVE');
  INSERT INTO t VALUES ('approver_identity_required', 'FAIL');
EXCEPTION WHEN raise_exception THEN INSERT INTO t VALUES ('approver_identity_required', 'PASS');
END $$;

DO $$ BEGIN
  UPDATE desk.agent_controls SET enabled = false;
  INSERT INTO t VALUES ('approver_cannot_update_controls_directly', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('approver_cannot_update_controls_directly', 'PASS');
END $$;

SELECT name, result FROM t ORDER BY name;
