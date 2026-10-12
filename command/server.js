// DESK_COMMAND: break desk command center on SPCS.
//   Live desk (Postgres, sub-second via LISTEN/NOTIFY -> SSE) + KPI dashboard (Snowflake mirror).
// Identity: the SPCS ingress authenticates the user and passes Sf-Context-Current-User; the endpoint
// is limited to the approver role via a service role. Every write records that user in the audit ledger.
const path = require('path');
const express = require('express');
const { approver, sim, listen } = require('./lib/pg');
const { query: sfQuery } = require('./lib/sf');
const { computeKpis } = require('./lib/kpis');

const PORT = Number(process.env.PORT || 8080);
const DESK_DB = process.env.DESK_DB || 'BREAK_DESK';
const app = express();
app.use(express.json({ limit: '64kb' }));

// ---------------------------------------------------------------- identity
function user(req) {
  return (req.get('Sf-Context-Current-User') || process.env.DEV_USER || '').trim();
}
app.use('/api', (req, res, next) => {
  if (req.path === '/health') return next();
  if (!user(req)) return res.status(401).json({ error: 'no Snowflake identity on request' });
  next();
});

// ---------------------------------------------------------------- SSE hub
const clients = new Set();
let listenUp = false;
function broadcast(type, data) {
  const msg = `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of clients) res.write(msg);
}
listen((channel, payload) => broadcast('pg', { channel, payload, at: Date.now() }),
       (up) => { listenUp = up; broadcast('listen', { up }); });

app.get('/api/stream', (req, res) => {
  res.set({ 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive',
            'X-Accel-Buffering': 'no' });
  res.flushHeaders();
  res.write(`event: listen\ndata: ${JSON.stringify({ up: listenUp })}\n\n`);
  clients.add(res);
  const ping = setInterval(() => res.write(': ping\n\n'), 15000);
  req.on('close', () => { clearInterval(ping); clients.delete(res); });
});

const wrap = (fn) => (req, res) => fn(req, res).catch((e) => {
  console.error(req.method, req.path, e.message);
  res.status(500).json({ error: e.message });
});

// ---------------------------------------------------------------- live desk (Postgres)
app.get('/api/health', (_req, res) => res.json({ ok: true, listen: listenUp }));
app.get('/api/me', (req, res) => res.json({ user: user(req) }));

app.get('/api/live', wrap(async (_req, res) => {
  const t0 = Date.now();
  const q = (sql) => approver.query(sql).then((r) => r.rows);
  const [queue, pending, agents, controls, events, wake, day] = await Promise.all([
    q('SELECT status, n FROM desk.v_queue'),
    q('SELECT * FROM desk.v_pending_actions ORDER BY tier DESC, created_at'),
    q('SELECT * FROM desk.v_agent_activity ORDER BY agent_role, worker_id'),
    q('SELECT agent_version, agent_role, enabled, model, prompt_version, updated_by, updated_at FROM desk.agent_controls ORDER BY agent_role, agent_version'),
    q('SELECT * FROM desk.v_recent_events LIMIT 40'),
    q('SELECT * FROM desk.v_wakeup_latency'),
    q('SELECT * FROM desk.v_current_day'),
  ]);
  res.json({ queue, pending, agents, controls, events, wake, day: day[0] || null, pg_ms: Date.now() - t0 });
}));

// ---------------------------------------------------------------- add breaks (DEMO catalog replay)
const SCENARIO_SQL = `
  SELECT BREAK_ID, TRADE_REF, CUSTODIAN, COUNTERPARTY_ID, ISIN, CURRENCY, SETTLE_DATE::STRING AS SETTLE_DATE,
         CUSTODIAN_MESSAGE, QTY_DIFF, PRICE_DIFF_BPS, CASH_DIFF, PRIORITY, EXPECTED_ACTION, SCENARIO, IS_QC_TRAP
    FROM ${DESK_DB}.REF.BREAK_SCENARIOS WHERE BATCH = 'DEMO' ORDER BY RANDOM() LIMIT ?`;

async function insertBreak(r, suffix) {
  const brk = {
    break_id: r.BREAK_ID + suffix, trade_ref: r.TRADE_REF, custodian: r.CUSTODIAN,
    counterparty_id: r.COUNTERPARTY_ID, isin: r.ISIN, currency: r.CURRENCY, settle_date: r.SETTLE_DATE,
    custodian_message: r.CUSTODIAN_MESSAGE, priority: r.PRIORITY,
    qty_diff: Number(r.QTY_DIFF), price_diff_bps: Number(r.PRICE_DIFF_BPS), cash_diff: Number(r.CASH_DIFF),
  };
  const truth = { expected_action: r.EXPECTED_ACTION, scenario: r.SCENARIO, is_qc_trap: r.IS_QC_TRAP };
  await sim.query('SELECT desk.insert_break($1::jsonb, $2::jsonb)', [JSON.stringify(brk), JSON.stringify(truth)]);
  return brk.break_id;
}

app.post('/api/breaks', wrap(async (req, res) => {
  const count = Math.max(1, Math.min(25, Number(req.body.count) || 5));
  const trickle = Boolean(req.body.trickle);
  const rows = await sfQuery(SCENARIO_SQL, [count]);
  const suffix = `-C${Date.now().toString(36).toUpperCase()}`;
  broadcast('sim', { by: user(req), count: rows.length, trickle });
  if (!trickle) {
    const ids = [];
    for (const r of rows) ids.push(await insertBreak(r, suffix));
    return res.json({ inserted: ids.length, ids });
  }
  // Trickle: one per second in the background so the audience sees each wake-up.
  (async () => {
    for (const r of rows) {
      try { await insertBreak(r, suffix); } catch (e) { console.error('trickle insert', e.message); }
      await new Promise((ok) => setTimeout(ok, 1000));
    }
  })();
  res.json({ inserted: 0, scheduled: rows.length, trickle: true });
}));

// ---------------------------------------------------------------- approvals
app.post('/api/actions/:id/decision', wrap(async (req, res) => {
  const { decision, sha256, note } = req.body || {};
  if (!['APPROVE', 'REJECT'].includes(decision)) return res.status(400).json({ error: 'decision must be APPROVE or REJECT' });
  if (!/^[0-9a-f]{64}$/.test(sha256 || '')) return res.status(400).json({ error: 'sha256 of the reviewed payload is required' });
  try {
    const r = await approver.query('SELECT desk.approve_action($1, $2, $3, $4, $5) AS result',
      [Number(req.params.id), sha256, user(req), decision, note || null]);
    res.json({ result: r.rows[0].result });
  } catch (e) {
    res.status(409).json({ error: e.message });   // governance refusals (QC hold, tier-2 w/o concur, stale)
  }
}));

// Bulk approval: each action still goes through approve_action with its own payload hash and the
// named user. Ineligible actions (QC hold, tier-2 without concurrence, PENDING_QC) are skipped.
app.post('/api/actions/approve-eligible', wrap(async (req, res) => {
  const who = user(req);
  const { rows } = await approver.query(
    `SELECT action_id, payload_sha256 FROM desk.v_pending_actions
      WHERE status = 'PENDING_APPROVAL' AND (tier < 2 OR qc_status = 'CONCUR') ORDER BY created_at`);
  const tally = { APPROVED: 0, HASH_MISMATCH: 0, EXPIRED: 0, refused: 0 };
  for (const a of rows) {
    try {
      const r = await approver.query('SELECT desk.approve_action($1, $2, $3, $4, $5) AS result',
        [a.action_id, a.payload_sha256, who, 'APPROVE', 'bulk end-of-day approval']);
      tally[r.rows[0].result] = (tally[r.rows[0].result] || 0) + 1;
    } catch (e) { tally.refused += 1; }
  }
  const skipped = (await approver.query(`SELECT count(*)::int AS n FROM desk.v_pending_actions`)).rows[0].n;
  res.json({ considered: rows.length, ...tally, still_pending: skipped });
}));

// ---------------------------------------------------------------- desk day + kill switch
app.post('/api/desk-day/close', wrap(async (req, res) => {
  const note = (req.body && req.body.note) ? String(req.body.note).slice(0, 200) : null;
  const r = await approver.query('SELECT desk.close_desk_day($1, $2) AS summary', [user(req), note]);
  kpiCache.clear();
  res.json(r.rows[0].summary);
}));

app.post('/api/controls/:version', wrap(async (req, res) => {
  const enabled = Boolean(req.body && req.body.enabled);
  try {
    await approver.query('SELECT desk.set_agent_control($1, $2, $3)', [req.params.version, enabled, user(req)]);
    res.json({ version: req.params.version, enabled });
  } catch (e) { res.status(409).json({ error: e.message }); }
}));

// ---------------------------------------------------------------- KPIs (Snowflake mirror), cached
const kpiCache = new Map();   // scope -> { at, data, pending }
const KPI_TTL_MS = 15000;

async function kpis(scope) {
  const hit = kpiCache.get(scope);
  if (hit && hit.data && Date.now() - hit.at < KPI_TTL_MS) return hit.data;
  if (hit && hit.pending) return hit.pending;
  const pending = (async () => {
    let since = '1970-01-01T00:00:00Z';
    if (scope === 'today') {
      const d = await approver.query('SELECT opened_at FROM desk.v_current_day');
      if (d.rows[0]) since = new Date(d.rows[0].opened_at).toISOString();
    }
    const data = { scope, ...(await computeKpis(since)) };
    kpiCache.set(scope, { at: Date.now(), data });
    return data;
  })();
  kpiCache.set(scope, { ...(hit || {}), pending });
  try { return await pending; } catch (e) { kpiCache.delete(scope); throw e; }
}

app.get('/api/kpis', wrap(async (req, res) => {
  res.json(await kpis(req.query.scope === 'all' ? 'all' : 'today'));
}));

// ---------------------------------------------------------------- static UI
app.use(express.static(path.join(__dirname, 'public'), { maxAge: '5m' }));
app.get('*', (_req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));

app.listen(PORT, () => console.log(`desk_command listening on :${PORT}`));
