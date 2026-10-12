-- Run as desk_app (investigator). Claims both test breaks and proposes actions.
CREATE TEMP TABLE t (name text, result text);
CREATE TEMP TABLE c AS SELECT * FROM desk.claim_break('test-worker', 'investigator-v1', 60);
INSERT INTO c SELECT * FROM desk.claim_break('test-worker', 'investigator-v1', 60);

INSERT INTO t SELECT 'claimed_two_breaks', CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END FROM c;

-- T-001: a cash movement must route to QC (tier 2) regardless of what the agent asks for
INSERT INTO t
SELECT 'cash_movement_routes_to_qc',
       CASE WHEN (a).status = 'PENDING_QC' AND (a).tier = 2 THEN 'PASS' ELSE 'FAIL ' || (a).status END
  FROM (SELECT desk.propose_action('T-001', (SELECT fence_token FROM c WHERE break_id = 'T-001'), 'run-t1',
               'test-worker', 'investigator-v1', 'claude-haiku-4-5', 'CASH_MOVEMENT',
               '{"amount":125000,"currency":"USD","to":"CP-1"}'::jsonb, 'test', '[]'::jsonb) AS a) s;

-- T-002: a 3 bps price difference is within the 5 bps rule, so tier 0 auto-approves
INSERT INTO t
SELECT 'small_price_diff_auto_approves',
       CASE WHEN (a).status = 'AUTO_APPROVED' AND (a).tier = 0 THEN 'PASS' ELSE 'FAIL ' || (a).status END
  FROM (SELECT desk.propose_action('T-002', (SELECT fence_token FROM c WHERE break_id = 'T-002'), 'run-t2',
               'test-worker', 'investigator-v1', 'claude-haiku-4-5', 'ACCEPT_PRICE_DIFF',
               '{"price_diff_bps":3}'::jsonb, 'test', '[]'::jsonb) AS a) s;

DO $$ BEGIN
  PERFORM desk.propose_action('T-001', 999, 'run-x', 'test-worker', 'investigator-v1', 'm', 'ESCALATE',
                              '{}'::jsonb, 'x', '[]'::jsonb);
  INSERT INTO t VALUES ('stale_fence_rejected', 'FAIL');
EXCEPTION WHEN raise_exception THEN INSERT INTO t VALUES ('stale_fence_rejected', 'PASS');
END $$;

DO $$ BEGIN
  PERFORM desk.approve_action(1, 'x', 'agent', 'APPROVE');
  INSERT INTO t VALUES ('agent_cannot_approve', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('agent_cannot_approve', 'PASS');
END $$;

DO $$ BEGIN
  PERFORM desk.execute_action(1, 'agent');
  INSERT INTO t VALUES ('agent_cannot_execute', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('agent_cannot_execute', 'PASS');
END $$;

DO $$ BEGIN
  PERFORM 1 FROM desk.break_truth LIMIT 1;
  INSERT INTO t VALUES ('agent_cannot_read_ground_truth', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('agent_cannot_read_ground_truth', 'PASS');
END $$;

SELECT name, result FROM t ORDER BY name;
