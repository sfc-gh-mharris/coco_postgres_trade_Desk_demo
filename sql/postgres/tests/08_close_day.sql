-- Close-of-day governance. Run as desk_approver_svc after 07_admin.
CREATE TEMP TABLE t (name text, result text);

DO $$
DECLARE s jsonb; d0 int;
BEGIN
  SELECT day_id INTO d0 FROM desk.v_current_day;
  s := desk.close_desk_day('test-approver', 'governance test');
  INSERT INTO t VALUES ('close_day_opens_new_day',
    CASE WHEN (s->>'new_day_id')::int > d0 THEN 'PASS' ELSE 'FAIL' END);
  INSERT INTO t VALUES ('close_day_leaves_no_open_actions',
    CASE WHEN NOT EXISTS (SELECT 1 FROM desk.v_pending_actions) THEN 'PASS' ELSE 'FAIL' END);
END $$;

DO $$ BEGIN
  PERFORM desk.close_desk_day('', NULL);
  INSERT INTO t VALUES ('close_day_requires_actor', 'FAIL');
EXCEPTION WHEN raise_exception THEN INSERT INTO t VALUES ('close_day_requires_actor', 'PASS');
END $$;

DO $$ BEGIN
  DELETE FROM desk.desk_days;
  INSERT INTO t VALUES ('approver_cannot_delete_desk_days', 'FAIL');
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t VALUES ('approver_cannot_delete_desk_days', 'PASS');
END $$;

SELECT name, result FROM t ORDER BY name;
