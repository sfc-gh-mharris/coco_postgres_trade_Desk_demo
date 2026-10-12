-- Break desk analytics on the Snowflake mirror of the Postgres desk (<PREFIX>_MIRROR.DESK). The installer writes a ready-to-run copy to build/sql/mirror_analytics.sql.
-- Open in a Snowsight worksheet and run statement-by-statement (Ctrl/Cmd+Enter on a query),
-- or Run All. Base tables are the ~30s mirror; $LIVE views read Postgres in real time;
-- $CHANGES views expose the CDC history (_CHANGE_TYPE, _COMMIT_TIME).
-- Every query is read-only.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE {{WH}};
USE SCHEMA {{MIRROR_DB}}.DESK;

-- ── 1. Desk at a glance ──────────────────────────────────────────────
SELECT
    (SELECT COUNT(*) FROM breaks)                                              AS breaks_total,
    (SELECT COUNT_IF(status = 'RESOLVED') FROM breaks)                         AS breaks_resolved,
    (SELECT COUNT_IF(status NOT IN ('RESOLVED', 'ESCALATED')) FROM breaks)     AS breaks_open,
    (SELECT COUNT_IF(status = 'PENDING_APPROVAL') FROM proposed_actions)       AS awaiting_human,
    (SELECT COUNT_IF(status = 'QC_HOLD') FROM proposed_actions)                AS qc_holds,
    (SELECT COUNT_IF(status = 'EXECUTED') FROM proposed_actions)               AS executed,
    (SELECT ROUND(SUM(ABS(cash_diff)), 2) FROM breaks WHERE status <> 'RESOLVED') AS open_cash_exposure;

-- ── 2. Mirror freshness: mirror vs $LIVE row counts and last commit seen ──
SELECT 'breaks' AS tbl,
       (SELECT COUNT(*) FROM breaks)             AS mirror_rows,
       (SELECT COUNT(*) FROM breaks$live)        AS live_rows,
       (SELECT MAX(_commit_time) FROM breaks$changes) AS last_commit
UNION ALL SELECT 'proposed_actions', (SELECT COUNT(*) FROM proposed_actions),
       (SELECT COUNT(*) FROM proposed_actions$live), (SELECT MAX(_commit_time) FROM proposed_actions$changes)
UNION ALL SELECT 'desk_events', (SELECT COUNT(*) FROM desk_events),
       (SELECT COUNT(*) FROM desk_events$live), (SELECT MAX(_commit_time) FROM desk_events$changes)
UNION ALL SELECT 'agent_runs', (SELECT COUNT(*) FROM agent_runs),
       (SELECT COUNT(*) FROM agent_runs$live), (SELECT MAX(_commit_time) FROM agent_runs$changes);

-- ── 3. Break pipeline by status and custodian (chart: stacked bar) ───
SELECT custodian, status, COUNT(*) AS breaks, ROUND(SUM(ABS(cash_diff)), 2) AS abs_cash
FROM breaks
GROUP BY custodian, status
ORDER BY custodian, breaks DESC;

-- ── 4. Proposed actions: type x tier x outcome ───────────────────────
SELECT action_type, tier, status, qc_status, COUNT(*) AS actions
FROM proposed_actions
GROUP BY ALL
ORDER BY action_type, tier, actions DESC;

-- ── 5. Agent accuracy vs ground truth (EVAL breaks in break_truth) ───
WITH latest AS (
    SELECT break_id, action_type
    FROM proposed_actions
    QUALIFY ROW_NUMBER() OVER (PARTITION BY break_id ORDER BY created_at DESC) = 1
)
SELECT t.scenario,
       COUNT(*)                                                 AS breaks,
       COUNT_IF(l.action_type = t.expected_action)              AS correct,
       ROUND(100 * DIV0NULL(COUNT_IF(l.action_type = t.expected_action), COUNT(*)), 1) AS accuracy_pct
FROM break_truth t
LEFT JOIN latest l ON l.break_id = t.break_id
GROUP BY t.scenario
ORDER BY accuracy_pct, breaks DESC;

-- ── 6. QC effectiveness: did QC hold the planted traps? ──────────────
SELECT t.is_qc_trap,
       q.verdict,
       COUNT(*) AS reviews
FROM qc_reviews q
JOIN proposed_actions a ON a.action_id = q.action_id
LEFT JOIN break_truth t ON t.break_id = a.break_id
GROUP BY ALL
ORDER BY t.is_qc_trap DESC NULLS LAST, q.verdict;

-- QC hold reasons (read in full)
SELECT q.action_id, a.break_id, a.action_type, q.verdict, q.reason, q.created_at
FROM qc_reviews q
JOIN proposed_actions a ON a.action_id = q.action_id
WHERE q.verdict = 'HOLD'
ORDER BY q.created_at DESC;

-- ── 7. Agent performance by role / version / model ───────────────────
SELECT agent_role, agent_version, model,
       COUNT(*)                                                       AS runs,
       ROUND(AVG(DATEDIFF('millisecond', started_at, ended_at)) / 1000, 1) AS avg_run_s,
       ROUND(APPROX_PERCENTILE(llm_ms, 0.5) / 1000, 1)                AS p50_llm_s,
       ROUND(APPROX_PERCENTILE(llm_ms, 0.95) / 1000, 1)               AS p95_llm_s,
       ROUND(AVG(turns), 1)                                           AS avg_turns,
       SUM(input_tokens)                                              AS input_tokens,
       SUM(output_tokens)                                             AS output_tokens
FROM agent_runs
GROUP BY ALL
ORDER BY agent_role, runs DESC;

-- Throughput per worker slot (how evenly SKIP LOCKED spreads the work)
SELECT worker_id, COUNT(*) AS runs, MIN(started_at) AS first_run, MAX(ended_at) AS last_run
FROM agent_runs
WHERE agent_role = 'investigator'
GROUP BY worker_id
ORDER BY runs DESC;

-- ── 8. Latency through the lifecycle (seconds, from desk_events) ─────
WITH ev AS (
    SELECT break_id,
           MIN(IFF(event_type = 'BREAK_RECEIVED',  occurred_at, NULL)) AS received_at,
           MIN(IFF(event_type = 'CLAIMED',         occurred_at, NULL)) AS claimed_at,
           MIN(IFF(event_type = 'ACTION_PROPOSED', occurred_at, NULL)) AS proposed_at,
           MIN(IFF(event_type = 'ACTION_EXECUTED', occurred_at, NULL)) AS executed_at
    FROM desk_events
    WHERE break_id IS NOT NULL
    GROUP BY break_id
)
SELECT 'insert -> claim'    AS stage, COUNT(claimed_at) AS n,
       ROUND(APPROX_PERCENTILE(DATEDIFF('millisecond', received_at, claimed_at), 0.5)  / 1000, 2) AS p50_s,
       ROUND(APPROX_PERCENTILE(DATEDIFF('millisecond', received_at, claimed_at), 0.95) / 1000, 2) AS p95_s
FROM ev
UNION ALL
SELECT 'claim -> proposal', COUNT(proposed_at),
       ROUND(APPROX_PERCENTILE(DATEDIFF('millisecond', claimed_at, proposed_at), 0.5)  / 1000, 2),
       ROUND(APPROX_PERCENTILE(DATEDIFF('millisecond', claimed_at, proposed_at), 0.95) / 1000, 2)
FROM ev
UNION ALL
SELECT 'insert -> executed', COUNT(executed_at),
       ROUND(APPROX_PERCENTILE(DATEDIFF('millisecond', received_at, executed_at), 0.5)  / 1000, 2),
       ROUND(APPROX_PERCENTILE(DATEDIFF('millisecond', received_at, executed_at), 0.95) / 1000, 2)
FROM ev;

-- ── 9. Event volume per minute by type (chart: line, x=minute) ───────
SELECT DATE_TRUNC('minute', occurred_at) AS minute, event_type, COUNT(*) AS events
FROM desk_events
GROUP BY ALL
ORDER BY minute, event_type;

-- ── 10. Governance: human approvals, kill-switch activity, blocks ────
SELECT occurred_at, event_type, actor_type, actor_id, break_id, action_id, agent_version, payload
FROM desk_events
WHERE event_type IN ('ACTION_APPROVED', 'AGENT_DISABLED', 'AGENT_ENABLED', 'BLOCKED_BY_KILL_SWITCH')
ORDER BY occurred_at DESC;

-- Who approved what, and how long it waited for a human
SELECT approved_by, action_type,
       COUNT(*) AS approvals,
       ROUND(AVG(DATEDIFF('second', created_at, approved_at)), 0) AS avg_wait_s
FROM proposed_actions
WHERE approved_at IS NOT NULL
GROUP BY ALL
ORDER BY approvals DESC;

-- Idempotency check: no key should settle twice (expect zero rows)
SELECT idempotency_key, COUNT(*) AS executions
FROM proposed_actions
WHERE executed_at IS NOT NULL
GROUP BY idempotency_key
HAVING COUNT(*) > 1;

-- Current agent controls (versions, models, kill-switch state) — live from Postgres
SELECT agent_version, agent_role, enabled, model, prompt_version, updated_by, updated_at
FROM agent_controls$live
ORDER BY agent_role, agent_version;

-- ── 11. CDC history: change volume per table (from $CHANGES views) ───
-- An UPDATE arrives as a D+I pair with _IS_UPDATE = TRUE; S = initial snapshot row.
WITH c AS (
    SELECT 'breaks' AS tbl, _change_type, _is_update FROM breaks$changes
    UNION ALL SELECT 'proposed_actions', _change_type, _is_update FROM proposed_actions$changes
    UNION ALL SELECT 'agent_controls',   _change_type, _is_update FROM agent_controls$changes
)
SELECT tbl,
       CASE WHEN _is_update THEN 'UPDATE'
            WHEN _change_type = 'I' THEN 'INSERT'
            WHEN _change_type = 'D' THEN 'DELETE'
            ELSE 'SNAPSHOT' END AS change_kind,
       COUNT(*) AS changes
FROM c
WHERE NOT (_is_update AND _change_type = 'D')
GROUP BY ALL
ORDER BY tbl, changes DESC;

-- Full status history of one break (edit the id)
SELECT _commit_time, IFF(_is_update, 'UPDATE', _change_type) AS change_kind,
       status, lease_owner, fence_token, attempts, claimed_version
FROM breaks$changes
WHERE break_id = (SELECT MIN(break_id) FROM breaks)
  AND NOT (_is_update AND _change_type = 'D')
ORDER BY _commit_lsn, _lsn;
