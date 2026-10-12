-- Break desk Postgres schema (Snowflake Postgres 18).
-- Applied from SPCS by scripts/pg_run.sh as snowflake_admin. Runs as one implicit transaction.
-- Re-running drops and recreates the desk schema, so run it only before demo data matters.
--
-- Governance model:
--   * Every state change goes through a SECURITY DEFINER function owned by desk_owner (NOLOGIN).
--   * Each login role can execute only the functions for its job; no direct table writes.
--   * desk_events is append-only (trigger blocks UPDATE/DELETE/TRUNCATE).
--   * Tier is computed from break data and policy_rules, never from the model's payload.
--   * Execution re-checks the kill switch, approval, QC verdict, expiry, and idempotency.

DROP SCHEMA IF EXISTS desk CASCADE;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'desk_owner') THEN
    CREATE ROLE desk_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'desk_app') THEN CREATE ROLE desk_app LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'desk_qc') THEN CREATE ROLE desk_qc LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'desk_exec') THEN CREATE ROLE desk_exec LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'desk_approver_svc') THEN CREATE ROLE desk_approver_svc LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'desk_sim') THEN CREATE ROLE desk_sim LOGIN; END IF;
END $$;

ALTER ROLE desk_app PASSWORD {{SECRET_PASSWORD:desk_app}};
ALTER ROLE desk_qc PASSWORD {{SECRET_PASSWORD:desk_qc}};
ALTER ROLE desk_exec PASSWORD {{SECRET_PASSWORD:desk_exec}};
ALTER ROLE desk_approver_svc PASSWORD {{SECRET_PASSWORD:desk_approver_svc}};
ALTER ROLE desk_sim PASSWORD {{SECRET_PASSWORD:desk_sim}};

GRANT desk_owner TO snowflake_admin;
CREATE SCHEMA desk AUTHORIZATION desk_owner;
SET ROLE desk_owner;
SET search_path = desk, pg_catalog;

-- ---------------------------------------------------------------- tables

CREATE TABLE desk.agent_controls (
  agent_version   text PRIMARY KEY,
  agent_role      text NOT NULL CHECK (agent_role IN ('investigator', 'qc')),
  enabled         boolean NOT NULL DEFAULT true,
  model           text NOT NULL,
  prompt_version  text NOT NULL,
  updated_by      text NOT NULL DEFAULT 'bootstrap',
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE desk.policy_rules (
  rule_id         text PRIMARY KEY,
  action_type     text NOT NULL,
  description     text NOT NULL,
  max_price_bps   numeric,          -- tier-0 ceiling for ACCEPT_PRICE_DIFF
  max_cash_amount numeric,          -- tier-1 ceiling for cash movement
  tier            int NOT NULL CHECK (tier IN (0, 1, 2)),
  qc_sample_pct   numeric NOT NULL DEFAULT 0 CHECK (qc_sample_pct BETWEEN 0 AND 100),
  active          boolean NOT NULL DEFAULT true,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE desk.breaks (
  break_id          text PRIMARY KEY,
  trade_ref         text NOT NULL,
  custodian         text NOT NULL,
  counterparty_id   text NOT NULL,
  isin              text NOT NULL,
  currency          text NOT NULL,
  settle_date       date NOT NULL,
  custodian_message text NOT NULL,
  qty_diff          numeric NOT NULL DEFAULT 0,
  price_diff_bps    numeric NOT NULL DEFAULT 0,
  cash_diff         numeric NOT NULL DEFAULT 0,
  priority          int NOT NULL DEFAULT 5,
  status            text NOT NULL DEFAULT 'NEW'
                    CHECK (status IN ('NEW', 'CLAIMED', 'PROPOSED', 'RESOLVED', 'ESCALATED', 'REOPENED')),
  lease_owner       text,
  lease_expires_at  timestamptz,
  fence_token       int NOT NULL DEFAULT 0,
  attempts          int NOT NULL DEFAULT 0,
  claimed_version   text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX breaks_claimable ON desk.breaks (status, priority DESC, created_at)
  WHERE status IN ('NEW', 'REOPENED', 'CLAIMED');

-- Ground truth for evaluation only. Never readable by investigator or QC roles.
CREATE TABLE desk.break_truth (
  break_id        text PRIMARY KEY REFERENCES desk.breaks (break_id),
  expected_action text NOT NULL,
  scenario        text NOT NULL,
  is_qc_trap      boolean NOT NULL DEFAULT false
);

CREATE TABLE desk.proposed_actions (
  action_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  break_id            text NOT NULL REFERENCES desk.breaks (break_id),
  fence_token         int NOT NULL,
  run_id              text NOT NULL,
  proposed_by_version text NOT NULL REFERENCES desk.agent_controls (agent_version),
  action_type         text NOT NULL
                      CHECK (action_type IN ('ACCEPT_PRICE_DIFF', 'REQUEST_SSI_UPDATE',
                                             'BOOK_QTY_ADJUSTMENT', 'CASH_MOVEMENT', 'ESCALATE')),
  payload             jsonb NOT NULL,
  payload_sha256      text NOT NULL,
  rationale           text NOT NULL,
  evidence_refs       jsonb NOT NULL DEFAULT '[]',
  tier                int NOT NULL,
  rule_id             text REFERENCES desk.policy_rules (rule_id),
  status              text NOT NULL
                      CHECK (status IN ('PENDING_QC', 'QC_HOLD', 'PENDING_APPROVAL', 'APPROVED',
                                        'AUTO_APPROVED', 'REJECTED', 'EXECUTED', 'BLOCKED', 'EXPIRED')),
  qc_status           text NOT NULL DEFAULT 'NOT_REQUIRED'
                      CHECK (qc_status IN ('NOT_REQUIRED', 'PENDING', 'SAMPLE_PENDING', 'CONCUR',
                                           'HOLD', 'DISAGREE')),
  qc_lease_owner      text,
  qc_lease_expires_at timestamptz,
  approved_by         text,
  approved_at         timestamptz,
  expires_at          timestamptz NOT NULL DEFAULT now() + interval '4 hours',
  idempotency_key     text NOT NULL UNIQUE,
  executed_at         timestamptz,
  executed_by         text,
  receipt             jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX actions_by_status ON desk.proposed_actions (status, qc_status);

CREATE TABLE desk.qc_reviews (
  review_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  action_id       bigint NOT NULL REFERENCES desk.proposed_actions (action_id),
  reviewer_version text NOT NULL REFERENCES desk.agent_controls (agent_version),
  model           text NOT NULL,
  review_kind     text NOT NULL CHECK (review_kind IN ('PRE_APPROVAL', 'POST_SAMPLE')),
  verdict         text NOT NULL CHECK (verdict IN ('CONCUR', 'HOLD', 'DISAGREE')),
  reason          text NOT NULL,
  evidence_refs   jsonb NOT NULL DEFAULT '[]',
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE desk.agent_runs (
  run_id          text PRIMARY KEY,
  break_id        text NOT NULL REFERENCES desk.breaks (break_id),
  worker_id       text NOT NULL,
  agent_version   text NOT NULL REFERENCES desk.agent_controls (agent_version),
  agent_role      text NOT NULL,
  model           text NOT NULL,
  started_at      timestamptz NOT NULL,
  ended_at        timestamptz NOT NULL,
  outcome         text NOT NULL,
  turns           int,
  input_tokens    int,
  output_tokens   int,
  llm_ms          int,
  tool_ms         int
);

CREATE TABLE desk.desk_events (
  event_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  break_id        text,
  action_id       bigint,
  run_id          text,
  actor_type      text NOT NULL CHECK (actor_type IN ('agent', 'qc', 'human', 'executor', 'system', 'simulator')),
  actor_id        text NOT NULL,
  event_type      text NOT NULL,
  agent_version   text,
  model           text,
  payload         jsonb NOT NULL DEFAULT '{}',
  occurred_at     timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX events_by_break ON desk.desk_events (break_id, event_id);

CREATE FUNCTION desk.reject_event_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'desk_events is append-only (% blocked)', TG_OP;
END $$;

CREATE TRIGGER desk_events_append_only
  BEFORE UPDATE OR DELETE ON desk.desk_events
  FOR EACH ROW EXECUTE FUNCTION desk.reject_event_mutation();
CREATE TRIGGER desk_events_no_truncate
  BEFORE TRUNCATE ON desk.desk_events
  FOR EACH STATEMENT EXECUTE FUNCTION desk.reject_event_mutation();

-- ---------------------------------------------------------------- helpers

CREATE FUNCTION desk.log_event(p_break_id text, p_action_id bigint, p_run_id text, p_actor_type text,
                               p_actor_id text, p_event_type text, p_version text, p_model text,
                               p_payload jsonb) RETURNS bigint
LANGUAGE sql AS $$
  INSERT INTO desk.desk_events (break_id, action_id, run_id, actor_type, actor_id, event_type,
                                agent_version, model, payload)
  VALUES (p_break_id, p_action_id, p_run_id, p_actor_type, p_actor_id, p_event_type, p_version,
          p_model, COALESCE(p_payload, '{}'::jsonb))
  RETURNING event_id;
$$;

CREATE FUNCTION desk.payload_hash(p jsonb) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(p::text, 'UTF8')), 'hex');
$$;

-- Deterministic tier from break data and active policy rules. The model's payload is not trusted.
CREATE FUNCTION desk.classify_tier(p_action_type text, p_break desk.breaks,
                                   OUT tier int, OUT rule_id text, OUT qc_sample_pct numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE r desk.policy_rules;
BEGIN
  FOR r IN SELECT * FROM desk.policy_rules
           WHERE action_type = p_action_type AND active ORDER BY tier LOOP
    IF (r.max_price_bps IS NULL OR abs(p_break.price_diff_bps) <= r.max_price_bps)
       AND (r.max_cash_amount IS NULL OR abs(p_break.cash_diff) <= r.max_cash_amount) THEN
      tier := r.tier; rule_id := r.rule_id; qc_sample_pct := r.qc_sample_pct;
      RETURN;
    END IF;
  END LOOP;
  tier := 2; rule_id := NULL; qc_sample_pct := 0;   -- no rule matched: most restrictive tier
END $$;

-- ---------------------------------------------------------------- simulator

CREATE FUNCTION desk.insert_break(p_break jsonb, p_truth jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
DECLARE v_id text := p_break->>'break_id';
BEGIN
  INSERT INTO desk.breaks (break_id, trade_ref, custodian, counterparty_id, isin, currency,
                           settle_date, custodian_message, qty_diff, price_diff_bps, cash_diff, priority)
  VALUES (v_id, p_break->>'trade_ref', p_break->>'custodian', p_break->>'counterparty_id',
          p_break->>'isin', p_break->>'currency', (p_break->>'settle_date')::date,
          p_break->>'custodian_message', COALESCE((p_break->>'qty_diff')::numeric, 0),
          COALESCE((p_break->>'price_diff_bps')::numeric, 0),
          COALESCE((p_break->>'cash_diff')::numeric, 0), COALESCE((p_break->>'priority')::int, 5));
  IF p_truth IS NOT NULL THEN
    INSERT INTO desk.break_truth VALUES (v_id, p_truth->>'expected_action', p_truth->>'scenario',
                                         COALESCE((p_truth->>'is_qc_trap')::boolean, false));
  END IF;
  PERFORM desk.log_event(v_id, NULL, NULL, 'simulator', session_user, 'BREAK_RECEIVED', NULL, NULL,
                         jsonb_build_object('custodian', p_break->>'custodian'));
  PERFORM pg_notify('breaks_new', v_id);
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------- investigator

CREATE FUNCTION desk.claim_break(p_worker text, p_agent_version text, p_lease_secs int DEFAULT 90)
RETURNS SETOF desk.breaks
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
DECLARE
  v_row desk.breaks;
  v_prev_owner text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM desk.agent_controls
                 WHERE agent_version = p_agent_version AND agent_role = 'investigator' AND enabled) THEN
    RETURN;   -- kill switch: disabled versions cannot claim new work
  END IF;

  -- Breaks that exhausted their attempts go to a human instead of looping between agents.
  WITH exhausted AS (
    UPDATE desk.breaks SET status = 'ESCALATED', lease_owner = NULL, lease_expires_at = NULL, updated_at = now()
     WHERE status = 'CLAIMED' AND lease_expires_at < now() AND attempts >= 3
     RETURNING break_id, attempts
  )
  INSERT INTO desk.desk_events (break_id, actor_type, actor_id, event_type, agent_version, payload)
  SELECT break_id, 'system', 'claim_break', 'ESCALATED_MAX_ATTEMPTS', p_agent_version,
         jsonb_build_object('attempts', attempts)
    FROM exhausted;

  SELECT * INTO v_row FROM desk.breaks
   WHERE status IN ('NEW', 'REOPENED')
      OR (status = 'CLAIMED' AND lease_expires_at < now() AND attempts < 3)
   ORDER BY priority DESC, created_at
   FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;

  v_prev_owner := CASE WHEN v_row.status = 'CLAIMED' THEN v_row.lease_owner END;

  UPDATE desk.breaks
     SET status = 'CLAIMED', lease_owner = p_worker, lease_expires_at = now() + make_interval(secs => p_lease_secs),
         fence_token = fence_token + 1, attempts = attempts + 1, claimed_version = p_agent_version,
         updated_at = now()
   WHERE break_id = v_row.break_id
   RETURNING * INTO v_row;

  PERFORM desk.log_event(v_row.break_id, NULL, NULL, 'agent', p_worker,
                         CASE WHEN v_prev_owner IS NULL THEN 'CLAIMED' ELSE 'RECLAIMED' END,
                         p_agent_version, NULL,
                         jsonb_build_object('fence_token', v_row.fence_token, 'previous_owner', v_prev_owner,
                                            'attempt', v_row.attempts));
  RETURN NEXT v_row;
END $$;

CREATE FUNCTION desk.heartbeat(p_break_id text, p_fence int, p_lease_secs int DEFAULT 90) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
BEGIN
  UPDATE desk.breaks SET lease_expires_at = now() + make_interval(secs => p_lease_secs), updated_at = now()
   WHERE break_id = p_break_id AND fence_token = p_fence AND status = 'CLAIMED';
  RETURN FOUND;
END $$;

CREATE FUNCTION desk.record_finding(p_break_id text, p_fence int, p_run_id text, p_worker text,
                                    p_version text, p_model text, p_finding jsonb) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM desk.breaks WHERE break_id = p_break_id AND fence_token = p_fence
                 AND status = 'CLAIMED') THEN
    RAISE EXCEPTION 'stale fence token % for break %', p_fence, p_break_id;
  END IF;
  RETURN desk.log_event(p_break_id, NULL, p_run_id, 'agent', p_worker, 'FINDING', p_version, p_model, p_finding);
END $$;

CREATE FUNCTION desk.propose_action(p_break_id text, p_fence int, p_run_id text, p_worker text,
                                    p_version text, p_model text, p_action_type text, p_payload jsonb,
                                    p_rationale text, p_evidence_refs jsonb)
RETURNS desk.proposed_actions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
DECLARE
  v_break desk.breaks;
  v_tier record;
  v_status text;
  v_qc text;
  v_action desk.proposed_actions;
BEGIN
  SELECT * INTO v_break FROM desk.breaks WHERE break_id = p_break_id FOR UPDATE;
  IF v_break.fence_token <> p_fence OR v_break.status <> 'CLAIMED' THEN
    RAISE EXCEPTION 'stale fence token % for break % (current %, status %)',
      p_fence, p_break_id, v_break.fence_token, v_break.status;
  END IF;

  SELECT * INTO v_tier FROM desk.classify_tier(p_action_type, v_break);

  IF v_tier.tier = 0 THEN
    v_status := 'AUTO_APPROVED';
    v_qc := CASE WHEN random() * 100 < v_tier.qc_sample_pct THEN 'SAMPLE_PENDING' ELSE 'NOT_REQUIRED' END;
  ELSIF v_tier.tier = 1 THEN
    v_status := 'PENDING_APPROVAL';
    v_qc := 'NOT_REQUIRED';
  ELSE
    v_status := 'PENDING_QC';
    v_qc := 'PENDING';
  END IF;

  INSERT INTO desk.proposed_actions (break_id, fence_token, run_id, proposed_by_version, action_type,
                                     payload, payload_sha256, rationale, evidence_refs, tier, rule_id,
                                     status, qc_status, approved_by, approved_at, idempotency_key)
  VALUES (p_break_id, p_fence, p_run_id, p_version, p_action_type, p_payload, desk.payload_hash(p_payload),
          p_rationale, COALESCE(p_evidence_refs, '[]'::jsonb), v_tier.tier, v_tier.rule_id, v_status, v_qc,
          CASE WHEN v_tier.tier = 0 THEN 'policy:' || v_tier.rule_id END,
          CASE WHEN v_tier.tier = 0 THEN now() END,
          p_break_id || ':' || p_fence || ':' || p_action_type)
  RETURNING * INTO v_action;

  UPDATE desk.breaks SET status = 'PROPOSED', lease_owner = NULL, lease_expires_at = NULL, updated_at = now()
   WHERE break_id = p_break_id;

  PERFORM desk.log_event(p_break_id, v_action.action_id, p_run_id, 'agent', p_worker, 'ACTION_PROPOSED',
                         p_version, p_model,
                         jsonb_build_object('action_type', p_action_type, 'tier', v_tier.tier,
                                            'rule_id', v_tier.rule_id, 'status', v_status,
                                            'qc_status', v_qc, 'payload_sha256', v_action.payload_sha256));

  IF v_status = 'AUTO_APPROVED' THEN
    PERFORM pg_notify('actions_approved', v_action.action_id::text);
  END IF;
  IF v_qc IN ('PENDING', 'SAMPLE_PENDING') THEN
    PERFORM pg_notify('qc_pending', v_action.action_id::text);
  END IF;
  RETURN v_action;
END $$;

CREATE FUNCTION desk.record_run(p_run jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
  INSERT INTO desk.agent_runs (run_id, break_id, worker_id, agent_version, agent_role, model, started_at,
                               ended_at, outcome, turns, input_tokens, output_tokens, llm_ms, tool_ms)
  VALUES (p_run->>'run_id', p_run->>'break_id', p_run->>'worker_id', p_run->>'agent_version',
          p_run->>'agent_role', p_run->>'model', (p_run->>'started_at')::timestamptz,
          (p_run->>'ended_at')::timestamptz, p_run->>'outcome', (p_run->>'turns')::int,
          (p_run->>'input_tokens')::int, (p_run->>'output_tokens')::int, (p_run->>'llm_ms')::int,
          (p_run->>'tool_ms')::int)
  ON CONFLICT (run_id) DO NOTHING;
$$;

-- ---------------------------------------------------------------- QC reviewer

CREATE FUNCTION desk.claim_qc(p_reviewer text, p_version text, p_lease_secs int DEFAULT 180)
RETURNS TABLE (action_id bigint, review_kind text, action_type text, payload jsonb, tier int,
               brk jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
#variable_conflict use_column
DECLARE v desk.proposed_actions;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM desk.agent_controls
                 WHERE agent_version = p_version AND agent_role = 'qc' AND enabled) THEN
    RETURN;
  END IF;
  SELECT * INTO v FROM desk.proposed_actions a
   WHERE a.qc_status IN ('PENDING', 'SAMPLE_PENDING')
     AND (a.qc_lease_expires_at IS NULL OR a.qc_lease_expires_at < now())
   ORDER BY a.qc_status, a.created_at
   FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;

  UPDATE desk.proposed_actions SET qc_lease_owner = p_reviewer,
         qc_lease_expires_at = now() + make_interval(secs => p_lease_secs), updated_at = now()
   WHERE proposed_actions.action_id = v.action_id;

  PERFORM desk.log_event(v.break_id, v.action_id, NULL, 'qc', p_reviewer, 'QC_CLAIMED', p_version, NULL,
                         jsonb_build_object('qc_status', v.qc_status));

  -- QC sees the proposed action and the break facts, not the investigator's rationale.
  RETURN QUERY
  SELECT v.action_id,
         CASE WHEN v.qc_status = 'PENDING' THEN 'PRE_APPROVAL' ELSE 'POST_SAMPLE' END,
         v.action_type, v.payload, v.tier,
         to_jsonb(b) - 'lease_owner' - 'lease_expires_at' - 'fence_token' - 'attempts' - 'claimed_version'
    FROM desk.breaks b WHERE b.break_id = v.break_id;
END $$;

CREATE FUNCTION desk.record_review(p_action_id bigint, p_reviewer text, p_version text, p_model text,
                                   p_verdict text, p_reason text, p_evidence_refs jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
DECLARE
  v desk.proposed_actions;
  v_kind text;
  v_outcome text;
BEGIN
  SELECT * INTO v FROM desk.proposed_actions WHERE action_id = p_action_id FOR UPDATE;
  IF v.qc_status NOT IN ('PENDING', 'SAMPLE_PENDING') OR v.qc_lease_owner IS DISTINCT FROM p_reviewer THEN
    RAISE EXCEPTION 'action % is not leased for review by %', p_action_id, p_reviewer;
  END IF;
  v_kind := CASE WHEN v.qc_status = 'PENDING' THEN 'PRE_APPROVAL' ELSE 'POST_SAMPLE' END;

  INSERT INTO desk.qc_reviews (action_id, reviewer_version, model, review_kind, verdict, reason, evidence_refs)
  VALUES (p_action_id, p_version, p_model, v_kind, p_verdict, p_reason, COALESCE(p_evidence_refs, '[]'::jsonb));

  IF v_kind = 'PRE_APPROVAL' THEN
    IF p_verdict = 'CONCUR' THEN
      UPDATE desk.proposed_actions SET status = 'PENDING_APPROVAL', qc_status = 'CONCUR', updated_at = now()
       WHERE action_id = p_action_id;
      v_outcome := 'READY_FOR_APPROVAL';
    ELSE
      UPDATE desk.proposed_actions SET status = 'QC_HOLD', qc_status = 'HOLD', updated_at = now()
       WHERE action_id = p_action_id;
      v_outcome := 'HELD';
    END IF;
  ELSE
    IF p_verdict = 'CONCUR' THEN
      UPDATE desk.proposed_actions SET qc_status = 'CONCUR', updated_at = now() WHERE action_id = p_action_id;
      v_outcome := 'SAMPLE_CONCUR';
    ELSE
      UPDATE desk.proposed_actions SET qc_status = 'DISAGREE', updated_at = now() WHERE action_id = p_action_id;
      UPDATE desk.breaks SET status = 'REOPENED', updated_at = now() WHERE break_id = v.break_id;
      v_outcome := 'QC_REVERSAL';
    END IF;
  END IF;

  PERFORM desk.log_event(v.break_id, p_action_id, NULL, 'qc', p_reviewer,
                         CASE WHEN v_outcome = 'QC_REVERSAL' THEN 'QC_REVERSAL' ELSE 'QC_REVIEWED' END,
                         p_version, p_model,
                         jsonb_build_object('verdict', p_verdict, 'review_kind', v_kind, 'outcome', v_outcome,
                                            'reason', left(p_reason, 500)));
  IF v_outcome = 'QC_REVERSAL' THEN
    PERFORM pg_notify('breaks_new', v.break_id);
  END IF;
  RETURN v_outcome;
END $$;

-- ---------------------------------------------------------------- human approver

CREATE FUNCTION desk.approve_action(p_action_id bigint, p_expected_sha256 text, p_approver text,
                                    p_decision text, p_note text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
DECLARE v desk.proposed_actions;
BEGIN
  IF p_approver IS NULL OR length(trim(p_approver)) = 0 THEN
    RAISE EXCEPTION 'approver identity is required';
  END IF;
  IF p_decision NOT IN ('APPROVE', 'REJECT') THEN
    RAISE EXCEPTION 'decision must be APPROVE or REJECT';
  END IF;
  SELECT * INTO v FROM desk.proposed_actions WHERE action_id = p_action_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'action % not found', p_action_id; END IF;

  IF p_decision = 'REJECT' THEN
    IF v.status NOT IN ('PENDING_APPROVAL', 'QC_HOLD') THEN
      RAISE EXCEPTION 'action % cannot be rejected from status %', p_action_id, v.status;
    END IF;
    UPDATE desk.proposed_actions SET status = 'REJECTED', approved_by = p_approver, approved_at = now(),
           updated_at = now() WHERE action_id = p_action_id;
    UPDATE desk.breaks SET status = 'ESCALATED', updated_at = now() WHERE break_id = v.break_id;
    PERFORM desk.log_event(v.break_id, p_action_id, NULL, 'human', p_approver, 'ACTION_REJECTED',
                           v.proposed_by_version, NULL, jsonb_build_object('note', p_note));
    RETURN 'REJECTED';
  END IF;

  IF v.status = 'QC_HOLD' THEN
    RAISE EXCEPTION 'action % is on QC hold and cannot be approved', p_action_id;
  END IF;
  IF v.status <> 'PENDING_APPROVAL' THEN
    RAISE EXCEPTION 'action % is not pending approval (status %)', p_action_id, v.status;
  END IF;
  IF v.tier = 2 AND v.qc_status <> 'CONCUR' THEN
    RAISE EXCEPTION 'tier-2 action % requires QC concurrence (qc_status %)', p_action_id, v.qc_status;
  END IF;
  -- Mismatch and expiry return a result instead of raising, so their audit events persist.
  IF v.payload_sha256 <> p_expected_sha256 THEN
    PERFORM desk.log_event(v.break_id, p_action_id, NULL, 'human', p_approver, 'APPROVAL_HASH_MISMATCH',
                           v.proposed_by_version, NULL, jsonb_build_object('expected', p_expected_sha256,
                                                                           'actual', v.payload_sha256));
    RETURN 'HASH_MISMATCH';
  END IF;
  IF v.expires_at <= now() THEN
    UPDATE desk.proposed_actions SET status = 'EXPIRED', updated_at = now() WHERE action_id = p_action_id;
    PERFORM desk.log_event(v.break_id, p_action_id, NULL, 'human', p_approver, 'ACTION_EXPIRED',
                           v.proposed_by_version, NULL, jsonb_build_object('expired_at', v.expires_at));
    RETURN 'EXPIRED';
  END IF;

  UPDATE desk.proposed_actions SET status = 'APPROVED', approved_by = p_approver, approved_at = now(),
         updated_at = now() WHERE action_id = p_action_id;
  PERFORM desk.log_event(v.break_id, p_action_id, NULL, 'human', p_approver, 'ACTION_APPROVED',
                         v.proposed_by_version, NULL,
                         jsonb_build_object('payload_sha256', v.payload_sha256, 'note', p_note));
  PERFORM pg_notify('actions_approved', p_action_id::text);
  RETURN 'APPROVED';
END $$;

CREATE FUNCTION desk.set_agent_control(p_version text, p_enabled boolean, p_actor text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
BEGIN
  IF p_actor IS NULL OR length(trim(p_actor)) = 0 THEN
    RAISE EXCEPTION 'actor identity is required';
  END IF;
  UPDATE desk.agent_controls SET enabled = p_enabled, updated_by = p_actor, updated_at = now()
   WHERE agent_version = p_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown agent version %', p_version; END IF;
  PERFORM desk.log_event(NULL, NULL, NULL, 'human', p_actor,
                         CASE WHEN p_enabled THEN 'AGENT_ENABLED' ELSE 'AGENT_DISABLED' END,
                         p_version, NULL, '{}'::jsonb);
  PERFORM pg_notify('agent_controls', p_version);
  RETURN p_enabled;
END $$;

-- ---------------------------------------------------------------- executor

CREATE FUNCTION desk.ready_actions(p_limit int DEFAULT 20) RETURNS SETOF bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
  SELECT action_id FROM desk.proposed_actions
   WHERE status IN ('APPROVED', 'AUTO_APPROVED') AND executed_at IS NULL
   ORDER BY approved_at LIMIT p_limit;
$$;

CREATE FUNCTION desk.execute_action(p_action_id bigint, p_executor text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = desk, pg_catalog AS $$
DECLARE
  v desk.proposed_actions;
  v_enabled boolean;
  v_receipt jsonb;
BEGIN
  SELECT * INTO v FROM desk.proposed_actions WHERE action_id = p_action_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'action % not found', p_action_id; END IF;

  IF v.executed_at IS NOT NULL THEN
    RETURN jsonb_build_object('result', 'ALREADY_EXECUTED', 'receipt', v.receipt);
  END IF;
  IF v.status NOT IN ('APPROVED', 'AUTO_APPROVED') THEN
    RETURN jsonb_build_object('result', 'NOT_EXECUTABLE', 'status', v.status);
  END IF;

  SELECT enabled INTO v_enabled FROM desk.agent_controls WHERE agent_version = v.proposed_by_version;
  IF NOT COALESCE(v_enabled, false) THEN
    UPDATE desk.proposed_actions SET status = 'BLOCKED', updated_at = now() WHERE action_id = p_action_id;
    UPDATE desk.breaks SET status = 'ESCALATED', updated_at = now() WHERE break_id = v.break_id;
    PERFORM desk.log_event(v.break_id, p_action_id, NULL, 'executor', p_executor, 'BLOCKED_BY_KILL_SWITCH',
                           v.proposed_by_version, NULL, jsonb_build_object('previous_status', v.status));
    RETURN jsonb_build_object('result', 'BLOCKED_BY_KILL_SWITCH');
  END IF;
  IF v.expires_at <= now() THEN
    UPDATE desk.proposed_actions SET status = 'EXPIRED', updated_at = now() WHERE action_id = p_action_id;
    PERFORM desk.log_event(v.break_id, p_action_id, NULL, 'executor', p_executor, 'ACTION_EXPIRED',
                           v.proposed_by_version, NULL, '{}'::jsonb);
    RETURN jsonb_build_object('result', 'EXPIRED');
  END IF;
  IF v.tier = 2 AND v.qc_status <> 'CONCUR' THEN
    RETURN jsonb_build_object('result', 'NOT_EXECUTABLE', 'reason', 'tier-2 without QC concurrence');
  END IF;

  v_receipt := jsonb_build_object('settlement_ref', 'SIM-' || v.idempotency_key,
                                  'simulated', true, 'action_type', v.action_type,
                                  'executed_at', now());
  UPDATE desk.proposed_actions SET status = 'EXECUTED', executed_at = now(), executed_by = p_executor,
         receipt = v_receipt, updated_at = now()
   WHERE action_id = p_action_id;
  UPDATE desk.breaks SET status = CASE WHEN v.action_type = 'ESCALATE' THEN 'ESCALATED' ELSE 'RESOLVED' END,
         updated_at = now()
   WHERE break_id = v.break_id AND status = 'PROPOSED';
  PERFORM desk.log_event(v.break_id, p_action_id, NULL, 'executor', p_executor, 'ACTION_EXECUTED',
                         v.proposed_by_version, NULL, v_receipt);
  RETURN jsonb_build_object('result', 'EXECUTED', 'receipt', v_receipt);
END $$;

-- ---------------------------------------------------------------- console views

CREATE VIEW desk.v_queue AS
  SELECT status, count(*) AS n FROM desk.breaks GROUP BY status;

CREATE VIEW desk.v_pending_actions AS
  SELECT a.action_id, a.break_id, a.action_type, a.payload, a.payload_sha256, a.rationale, a.evidence_refs,
         a.tier, a.rule_id, a.status, a.qc_status, a.proposed_by_version, a.expires_at, a.created_at,
         b.custodian, b.counterparty_id, b.isin, b.currency, b.cash_diff, b.qty_diff, b.price_diff_bps,
         b.custodian_message,
         (SELECT r.verdict FROM desk.qc_reviews r WHERE r.action_id = a.action_id ORDER BY r.review_id DESC LIMIT 1) AS qc_verdict,
         (SELECT r.reason FROM desk.qc_reviews r WHERE r.action_id = a.action_id ORDER BY r.review_id DESC LIMIT 1) AS qc_reason,
         (SELECT r.model FROM desk.qc_reviews r WHERE r.action_id = a.action_id ORDER BY r.review_id DESC LIMIT 1) AS qc_model
    FROM desk.proposed_actions a JOIN desk.breaks b USING (break_id)
   WHERE a.status IN ('PENDING_QC', 'QC_HOLD', 'PENDING_APPROVAL');

CREATE VIEW desk.v_recent_events AS
  SELECT event_id, break_id, action_id, actor_type, actor_id, event_type, agent_version, model, payload,
         occurred_at
    FROM desk.desk_events ORDER BY event_id DESC LIMIT 200;

-- ---------------------------------------------------------------- privileges

RESET ROLE;

REVOKE ALL ON SCHEMA desk FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA desk FROM PUBLIC;
GRANT USAGE ON SCHEMA desk TO desk_app, desk_qc, desk_exec, desk_approver_svc, desk_sim;

GRANT EXECUTE ON FUNCTION desk.claim_break(text, text, int), desk.heartbeat(text, int, int),
                          desk.record_finding(text, int, text, text, text, text, jsonb),
                          desk.propose_action(text, int, text, text, text, text, text, jsonb, text, jsonb),
                          desk.record_run(jsonb)
      TO desk_app;
GRANT SELECT ON desk.agent_controls TO desk_app, desk_qc, desk_exec;

GRANT EXECUTE ON FUNCTION desk.claim_qc(text, text, int),
                          desk.record_review(bigint, text, text, text, text, text, jsonb),
                          desk.record_run(jsonb)
      TO desk_qc;

GRANT EXECUTE ON FUNCTION desk.ready_actions(int), desk.execute_action(bigint, text) TO desk_exec;

GRANT EXECUTE ON FUNCTION desk.approve_action(bigint, text, text, text, text),
                          desk.set_agent_control(text, boolean, text)
      TO desk_approver_svc;
GRANT SELECT ON desk.v_queue, desk.v_pending_actions, desk.v_recent_events, desk.agent_controls,
                desk.policy_rules
      TO desk_approver_svc;

GRANT EXECUTE ON FUNCTION desk.insert_break(jsonb, jsonb) TO desk_sim;

-- Snowflake mirroring reads tables through these managed roles (mirrors public's grants).
GRANT USAGE ON SCHEMA desk TO snowflake_read_only;
GRANT SELECT ON ALL TABLES IN SCHEMA desk TO snowflake_read_only;

-- ---------------------------------------------------------------- seed controls and policy

SET ROLE desk_owner;
INSERT INTO desk.agent_controls (agent_version, agent_role, model, prompt_version) VALUES
  ('investigator-v1', 'investigator', '{{INVESTIGATOR_MODEL}}', 'inv-p2'),
  ('investigator-v2', 'investigator', '{{INVESTIGATOR_ALT_MODEL}}', 'inv-p2'),
  ('qc-v1', 'qc', '{{QC_MODEL}}', 'qc-p1');
-- Canary with a loosened cash rule (staged regression for the demo); off until rolled out.
INSERT INTO desk.agent_controls (agent_version, agent_role, enabled, model, prompt_version) VALUES
  ('investigator-v3', 'investigator', false, '{{INVESTIGATOR_MODEL}}', 'inv-p3-loose');

INSERT INTO desk.policy_rules (rule_id, action_type, description, max_price_bps, max_cash_amount, tier, qc_sample_pct) VALUES
  ('R0-PRICE-TOL', 'ACCEPT_PRICE_DIFF', 'Accept price difference within 5 bps tolerance', 5, NULL, 0, 10),
  ('R1-PRICE', 'ACCEPT_PRICE_DIFF', 'Price difference above tolerance needs approval', NULL, NULL, 1, 0),
  ('R1-SSI', 'REQUEST_SSI_UPDATE', 'Request corrected settlement instructions from counterparty', NULL, NULL, 1, 0),
  ('R1-QTY', 'BOOK_QTY_ADJUSTMENT', 'Book quantity adjustment to match custodian', NULL, NULL, 1, 0),
  ('R1-ESC', 'ESCALATE', 'Escalate to operations analyst', NULL, NULL, 1, 0),
  ('R2-CASH', 'CASH_MOVEMENT', 'Any cash movement requires QC and human approval', NULL, NULL, 2, 0);
RESET ROLE;

SELECT 'desk schema ready' AS status,
       (SELECT count(*) FROM desk.agent_controls) AS agent_versions,
       (SELECT count(*) FROM desk.policy_rules) AS policy_rules;
