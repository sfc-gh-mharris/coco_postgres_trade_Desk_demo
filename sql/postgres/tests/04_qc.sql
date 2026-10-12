-- Run as desk_qc. Reviews the T-001 cash movement and concurs.
CREATE TEMP TABLE t (name text, result text);
CREATE TEMP TABLE q AS SELECT * FROM desk.claim_qc('test-qc', 'qc-v1', 60);

INSERT INTO t SELECT 'qc_claims_pending_cash_action',
  CASE WHEN count(*) = 1 AND max(review_kind) = 'PRE_APPROVAL' AND bool_and(NOT (brk ? 'fence_token'))
       THEN 'PASS' ELSE 'FAIL' END FROM q;

INSERT INTO t SELECT 'qc_concur_moves_to_approval',
  CASE WHEN desk.record_review((SELECT action_id FROM q), 'test-qc', 'qc-v1', 'claude-opus-5-5', 'CONCUR',
                               'cash difference matches custodian statement', '[]'::jsonb) = 'READY_FOR_APPROVAL'
       THEN 'PASS' ELSE 'FAIL' END;

DO $$ BEGIN
  PERFORM desk.approve_action(1, 'x', 'qc', 'APPROVE');
  INSERT INTO t VALUES ('qc_cannot_approve', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('qc_cannot_approve', 'PASS');
END $$;

SELECT name, result FROM t ORDER BY name;
