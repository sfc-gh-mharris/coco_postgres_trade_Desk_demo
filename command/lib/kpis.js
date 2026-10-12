// Dashboard KPIs from the Snowflake mirror of the Postgres desk (<MIRROR_DB>.DESK).
// Every query is scoped to "since" (start of the current desk day, or epoch for all-time).
const { query } = require('./sf');

const S = 'TO_TIMESTAMP_LTZ(?)';

const Q = {
  summary: `
    SELECT COUNT(*)                                                         AS received,
           COUNT_IF(status = 'RESOLVED')                                    AS resolved,
           COUNT_IF(status = 'ESCALATED')                                   AS escalated,
           COUNT_IF(status IN ('NEW','CLAIMED','PROPOSED','REOPENED'))      AS open,
           ROUND(SUM(IFF(status IN ('NEW','CLAIMED','PROPOSED','REOPENED'), ABS(cash_diff), 0)), 2) AS open_cash,
           ROUND(SUM(IFF(status = 'RESOLVED', ABS(cash_diff), 0)), 2)       AS resolved_cash
      FROM breaks WHERE created_at >= ${S}`,
  actions: `
    SELECT COUNT(*)                                                         AS proposed,
           COUNT_IF(status = 'EXECUTED' AND approved_by IS NULL)            AS auto_executed,
           COUNT_IF(status = 'EXECUTED' AND approved_by IS NOT NULL)        AS human_executed,
           COUNT_IF(status = 'PENDING_APPROVAL')                            AS awaiting_human,
           COUNT_IF(status = 'QC_HOLD')                                     AS qc_hold,
           COUNT_IF(status = 'BLOCKED')                                     AS blocked,
           COUNT_IF(status = 'REJECTED')                                    AS rejected,
           ROUND(AVG(IFF(approved_at IS NOT NULL, DATEDIFF('second', created_at, approved_at), NULL)), 0) AS avg_human_wait_s
      FROM proposed_actions WHERE created_at >= ${S}`,
  latency: `
    WITH ev AS (
      SELECT break_id,
             MIN(IFF(event_type = 'BREAK_RECEIVED',  occurred_at, NULL)) AS rcv,
             MIN(IFF(event_type = 'CLAIMED',         occurred_at, NULL)) AS clm,
             MIN(IFF(event_type = 'ACTION_PROPOSED', occurred_at, NULL)) AS prp,
             MIN(IFF(event_type = 'ACTION_EXECUTED', occurred_at, NULL)) AS exe
        FROM desk_events WHERE break_id IS NOT NULL AND occurred_at >= ${S}
       GROUP BY break_id)
    SELECT APPROX_PERCENTILE(DATEDIFF('millisecond', rcv, clm), 0.5)  AS claim_p50_ms,
           APPROX_PERCENTILE(DATEDIFF('millisecond', rcv, clm), 0.95) AS claim_p95_ms,
           MIN(DATEDIFF('millisecond', rcv, clm))                     AS claim_min_ms,
           APPROX_PERCENTILE(DATEDIFF('millisecond', clm, prp), 0.5)  AS review_p50_ms,
           APPROX_PERCENTILE(DATEDIFF('millisecond', rcv, exe), 0.5)  AS resolve_p50_ms,
           APPROX_PERCENTILE(DATEDIFF('millisecond', rcv, exe), 0.95) AS resolve_p95_ms
      FROM ev WHERE rcv IS NOT NULL`,
  byCustodian: `
    SELECT custodian, status, COUNT(*) AS n FROM breaks WHERE created_at >= ${S}
     GROUP BY ALL ORDER BY custodian`,
  byCurrency: `
    SELECT currency, ROUND(SUM(ABS(cash_diff)), 2) AS open_cash, COUNT(*) AS n
      FROM breaks WHERE created_at >= ${S} AND status IN ('NEW','CLAIMED','PROPOSED','REOPENED')
     GROUP BY currency ORDER BY open_cash DESC`,
  actionMix: `
    SELECT action_type, COUNT(*) AS n FROM proposed_actions WHERE created_at >= ${S}
     GROUP BY action_type ORDER BY n DESC`,
  perMinute: `
    SELECT TO_CHAR(DATE_TRUNC('minute', occurred_at), 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM') AS minute,
           COUNT_IF(event_type = 'BREAK_RECEIVED')  AS received,
           COUNT_IF(event_type = 'ACTION_PROPOSED') AS proposed,
           COUNT_IF(event_type = 'ACTION_EXECUTED') AS executed
      FROM desk_events
     WHERE occurred_at >= GREATEST(${S}, DATEADD('minute', -60, CURRENT_TIMESTAMP()))
     GROUP BY 1 ORDER BY 1`,
  aging: `
    SELECT COUNT_IF(age_m < 5) AS lt5, COUNT_IF(age_m >= 5 AND age_m < 30) AS m5_30, COUNT_IF(age_m >= 30) AS gt30
      FROM (SELECT DATEDIFF('minute', created_at, CURRENT_TIMESTAMP()) AS age_m FROM breaks
             WHERE created_at >= ${S} AND status IN ('NEW','CLAIMED','PROPOSED','REOPENED'))`,
  quality: `
    WITH latest AS (
      SELECT break_id, action_type FROM proposed_actions WHERE created_at >= ${S}
      QUALIFY ROW_NUMBER() OVER (PARTITION BY break_id ORDER BY created_at DESC) = 1)
    SELECT COUNT(*)                                             AS judged,
           COUNT_IF(l.action_type = t.expected_action)          AS correct,
           COUNT_IF(t.is_qc_trap)                               AS traps,
           COUNT_IF(t.is_qc_trap AND a.qc_status = 'HOLD')      AS traps_held
      FROM latest l
      JOIN break_truth t ON t.break_id = l.break_id
      LEFT JOIN (SELECT break_id, MAX_BY(qc_status, created_at) AS qc_status FROM proposed_actions GROUP BY break_id) a
        ON a.break_id = l.break_id`,
  governance: `
    SELECT COUNT_IF(event_type = 'ACTION_APPROVED')         AS hash_bound_approvals,
           COUNT_IF(event_type = 'APPROVAL_HASH_MISMATCH')  AS hash_mismatches,
           COUNT_IF(event_type = 'BLOCKED_BY_KILL_SWITCH')  AS kill_blocks,
           COUNT_IF(event_type IN ('AGENT_DISABLED','AGENT_ENABLED')) AS control_changes,
           COUNT_IF(event_type = 'QC_REVIEWED')             AS qc_reviews,
           COUNT(*)                                         AS ledger_events
      FROM desk_events WHERE occurred_at >= ${S}`,
  doubleSettle: `
    SELECT COUNT(*) AS n FROM (
      SELECT idempotency_key FROM proposed_actions WHERE executed_at IS NOT NULL
       GROUP BY idempotency_key HAVING COUNT(*) > 1)`,
  agents: `
    SELECT agent_role, model, COUNT(*) AS runs,
           ROUND(APPROX_PERCENTILE(llm_ms, 0.5)) AS llm_p50_ms,
           ROUND(AVG(DATEDIFF('millisecond', started_at, ended_at))) AS run_avg_ms,
           SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
           COUNT(DISTINCT worker_id) AS slots
      FROM agent_runs WHERE started_at >= ${S}
     GROUP BY ALL ORDER BY agent_role, runs DESC`,
  slots: `
    SELECT worker_id, COUNT(*) AS runs FROM agent_runs
     WHERE started_at >= ${S} AND agent_role = 'investigator'
     GROUP BY worker_id ORDER BY worker_id`,
  freshness: `
    SELECT (SELECT COUNT(*) FROM breaks)            AS mirror_breaks,
           (SELECT COUNT(*) FROM breaks$live)       AS live_breaks,
           (SELECT COUNT(*) FROM desk_events)       AS mirror_events,
           (SELECT COUNT(*) FROM desk_events$live)  AS live_events,
           (SELECT MAX(occurred_at) FROM desk_events)        AS mirror_last_event,
           (SELECT MAX(occurred_at) FROM desk_events$live)   AS live_last_event,
           (SELECT COUNT(*) FROM desk_days) - 1     AS days_closed`,
};

// Lowercase the column keys the SDK returns (Snowflake upper-cases unquoted identifiers).
const lower = (rows) => rows.map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [k.toLowerCase(), v])));

async function computeKpis(sinceIso) {
  const t0 = Date.now();
  const names = Object.keys(Q);
  const results = await Promise.all(names.map((n) => {
    const sql = Q[n];
    const binds = Array((sql.match(/TO_TIMESTAMP_LTZ\(\?\)/g) || []).length).fill(sinceIso);
    return query(sql, binds).then(lower);
  }));
  const out = Object.fromEntries(names.map((n, i) => [n, results[i]]));
  for (const one of ['summary', 'actions', 'latency', 'aging', 'quality', 'governance', 'doubleSettle', 'freshness']) {
    out[one] = out[one][0] || {};
  }
  out.query_ms = Date.now() - t0;
  out.as_of = new Date().toISOString();
  out.since = sinceIso;
  return out;
}

module.exports = { computeKpis };
