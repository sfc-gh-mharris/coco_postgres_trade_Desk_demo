-- Stage 2 governance tests. Run as desk_sim (inserts), then the role-specific scripts.
-- Each check uses a savepoint-free DO block that records PASS/FAIL into a temp table.
CREATE TEMP TABLE t (name text, result text);

-- seed two test breaks through the simulator's only entry point
SELECT desk.insert_break('{"break_id":"T-001","trade_ref":"TR-T1","custodian":"BNYM","counterparty_id":"CP-1","isin":"US0378331005","currency":"USD","settle_date":"2026-10-09","custodian_message":"test","cash_diff":125000,"priority":9}'::jsonb, NULL);
SELECT desk.insert_break('{"break_id":"T-002","trade_ref":"TR-T2","custodian":"STATE ST","counterparty_id":"CP-2","isin":"US5949181045","currency":"USD","settle_date":"2026-10-09","custodian_message":"test","price_diff_bps":3,"priority":1}'::jsonb, NULL);

DO $$ BEGIN
  INSERT INTO desk.breaks (break_id, trade_ref, custodian, counterparty_id, isin, currency, settle_date, custodian_message)
  VALUES ('X', 'x', 'x', 'x', 'x', 'x', now(), 'x');
  INSERT INTO t VALUES ('sim_cannot_write_tables_directly', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('sim_cannot_write_tables_directly', 'PASS');
END $$;

DO $$ BEGIN
  PERFORM desk.claim_break('w', 'investigator-v1', 60);
  INSERT INTO t VALUES ('sim_cannot_claim', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('sim_cannot_claim', 'PASS');
END $$;

SELECT name, result FROM t ORDER BY name;
