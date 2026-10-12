// Break Desk Command: client. Live desk from /api/live (refreshed on Postgres NOTIFY via SSE),
// dashboard from /api/kpis (Snowflake mirror). All server text is escaped before rendering.
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (v) => (v === null || v === undefined || v === '' ? null : Number(v));
  const fmt = (v, d = 0) => (num(v) === null || Number.isNaN(num(v)) ? '—' : num(v).toLocaleString(undefined, { maximumFractionDigits: d, minimumFractionDigits: d }));
  const money = (v) => (num(v) === null ? '—' : num(v).toLocaleString(undefined, { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }));
  const ms = (v) => { const n = num(v); if (n === null) return '—'; return n < 1000 ? `${Math.round(n)} ms` : n < 60000 ? `${(n / 1000).toFixed(1)} s` : `${(n / 60000).toFixed(1)} min`; };
  const ago = (t) => { if (!t) return '—'; const s = Math.max(0, (Date.now() - new Date(t)) / 1000); return s < 60 ? `${Math.round(s)}s` : s < 3600 ? `${Math.round(s / 60)}m` : `${Math.round(s / 3600)}h`; };
  const hhmmss = (t) => new Date(t).toLocaleTimeString([], { hour12: false });

  const state = { scope: 'today', live: null, kpis: null, seenEvents: new Set(), seenCards: new Set(), firstLoad: true };

  async function api(path, opts = {}) {
    const res = await fetch(path, { headers: { 'Content-Type': 'application/json' }, ...opts });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || `${res.status} ${res.statusText}`);
    return body;
  }
  const post = (path, body) => api(path, { method: 'POST', body: JSON.stringify(body || {}) });

  let toastTimer;
  function toast(msg, err) {
    const t = $('toast'); t.textContent = msg; t.className = `toast on${err ? ' err' : ''}`;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.className = 'toast'; }, 4500);
  }

  // ------------------------------------------------------------ architecture strip
  const EVENT_NODE = {
    BREAK_RECEIVED: 'pg', CLAIMED: 'agent', RECLAIMED: 'agent', FINDING: 'agent', ACTION_PROPOSED: 'agent',
    QC_CLAIMED: 'qc', QC_REVIEWED: 'qc', QC_REVERSAL: 'qc', ACTION_APPROVED: 'human', ACTION_REJECTED: 'human',
    APPROVAL_HASH_MISMATCH: 'human', ACTION_EXECUTED: 'exec', BLOCKED_BY_KILL_SWITCH: 'exec',
    AGENT_DISABLED: 'exec', AGENT_ENABLED: 'exec', DAY_CLOSED: 'human', DESK_DAY_OPENED: 'human',
  };
  const CHANNEL_NODE = { breaks_new: 'pg', qc_pending: 'qc', actions_approved: 'exec', agent_controls: 'exec', desk_day: 'human' };
  function flash(n) {
    const el = document.querySelector(`.arch .node[data-n="${n}"]`); if (!el) return;
    el.classList.add('flash'); clearTimeout(el._t); el._t = setTimeout(() => el.classList.remove('flash'), 900);
  }

  // ------------------------------------------------------------ live desk
  function renderTop(live) {
    const killed = live.controls.filter((c) => c.agent_role === 'investigator' && !c.enabled).map((c) => c.agent_version);
    const active = live.controls.filter((c) => c.enabled).length;
    const pk = $('pill-kill');
    pk.textContent = `Agents ${active}/${live.controls.length} enabled`;
    pk.className = `pill ${active ? 'ok' : 'bad'}`;
    pk.title = killed.length ? `Disabled: ${killed.join(', ')}` : '';
    if (live.day) {
      $('pill-day').textContent = `Desk day #${live.day.day_id} · opened ${ago(live.day.opened_at)} ago`;
      const s = live.day.closed_summary;
      $('dayinfo').innerHTML = s
        ? `Previous close by <b>${esc(s.closed_by)}</b>: ${fmt(s.breaks_carried)} breaks carried to exceptions, ${fmt(s.actions_expired)} actions expired, ${fmt(s.leases_fenced)} leases fenced.`
        : 'No end-of-day close yet. Closing escalates open breaks and expires open actions &mdash; nothing is deleted.';
    }
  }

  function renderAgents(live) {
    const rows = live.agents.length ? live.agents : [];
    const busy = rows.filter((a) => a.busy).length;
    $('agents-sub').textContent = `${busy} working · ${rows.length} slots seen in last hour`;
    $('slots').innerHTML = rows.map((a) => {
      const role = a.agent_role === 'qc' ? 'qc' : 'inv';
      const st = a.busy
        ? `working ${esc(a.busy_action_id ? `action #${a.busy_action_id}` : a.busy_break_id)} · ${ago(a.busy_since)}`
        : `idle · last run ${ago(a.last_run_at)} ago`;
      return `<div class="slot ${role}${a.busy ? ' busy' : ''}">
        <div class="role">${esc(a.agent_role)} · ${esc(a.agent_version || '')}</div>
        <div class="wid">${esc(String(a.worker_id || '').split(':').pop())}</div>
        <div class="st">${st}</div>
        <div class="role">${fmt(a.runs_10m)} runs /10m · llm ${ms(a.avg_llm_ms)}</div></div>`;
    }).join('') || '<div class="empty">No agent activity in the last hour.</div>';
    $('controls').innerHTML = live.controls.map((c) => `
      <span class="ctl${c.enabled ? '' : ' off'}"><span class="v">${esc(c.agent_version)}</span>
        <span class="tag">${esc(c.model)}</span>
        <button class="btn sm ${c.enabled ? 'bad' : 'good'}" data-ctl="${esc(c.agent_version)}" data-en="${c.enabled ? '0' : '1'}">
          ${c.enabled ? 'Kill' : 'Enable'}</button></span>`).join('');
  }

  function eligibility(a) {
    if (a.status === 'QC_HOLD') return 'QC hold — approval blocked';
    if (a.status === 'PENDING_QC') return 'Awaiting QC agent';
    if (a.tier === 2 && a.qc_status !== 'CONCUR') return 'Tier 2 needs QC concurrence';
    return null;
  }

  function renderApprovals(live) {
    const list = live.pending;
    const ready = list.filter((a) => !eligibility(a)).length;
    $('queue-sub').textContent = `${ready} ready · ${list.length - ready} gated by QC`;
    $('btn-bulk').textContent = `Approve all eligible (${ready})`;
    $('btn-bulk').disabled = ready === 0;
    if (!list.length) { $('approvals').innerHTML = '<div class="empty">Queue is clear. Add breaks to start the flow.</div>'; return; }
    $('approvals').innerHTML = list.map((a) => {
      const gate = eligibility(a);
      const cls = a.status === 'QC_HOLD' ? 'hold' : a.tier === 2 ? 't2' : 't1';
      const qc = a.qc_verdict
        ? `<span class="tag ${a.qc_verdict === 'CONCUR' ? 'ok' : 'bad'}">QC ${esc(a.qc_verdict)}</span><span class="meta">${esc(a.qc_reason || '')}</span>`
        : '';
      const isNew = !state.firstLoad && !state.seenCards.has(a.action_id);
      return `<div class="acard ${cls}"${isNew ? '' : ' style="animation:none"'}>
        <div class="hd"><span class="ty">#${esc(a.action_id)} ${esc(a.action_type)}</span>
          <span><span class="tag t${esc(a.tier)}">tier ${esc(a.tier)}</span><span class="tag">${esc(a.status)}</span></span></div>
        <div class="meta">${esc(a.break_id)} · ${esc(a.custodian)} · ${esc(a.currency)} cash ${fmt(a.cash_diff, 2)} · qty ${fmt(a.qty_diff)} · ${fmt(a.price_diff_bps, 1)} bps · by ${esc(a.proposed_by_version)} · ${ago(a.created_at)} ago</div>
        <div class="why">${esc(a.rationale)}</div>
        <div>${qc}</div>
        <pre>${esc(JSON.stringify(a.payload, null, 1))}</pre>
        <div class="act">
          <button class="btn sm good" data-dec="APPROVE" data-id="${esc(a.action_id)}" data-sha="${esc(a.payload_sha256)}" ${gate ? 'disabled' : ''}>Approve</button>
          <button class="btn sm bad" data-dec="REJECT" data-id="${esc(a.action_id)}" data-sha="${esc(a.payload_sha256)}" ${a.status === 'PENDING_QC' ? 'disabled' : ''}>Reject</button>
          <span class="hash" title="${esc(a.payload_sha256)}">sha256 ${esc(String(a.payload_sha256).slice(0, 12))}…</span>
          ${gate ? `<span class="tag warn">${esc(gate)}</span>` : ''}
        </div></div>`;
    }).join('');
    list.forEach((a) => state.seenCards.add(a.action_id));
  }

  function describe(e) {
    const p = e.payload || {};
    if (e.event_type === 'BREAK_RECEIVED') return p.custodian || '';
    if (e.event_type === 'CLAIMED' || e.event_type === 'RECLAIMED') return `fence ${p.fence_token ?? ''}`;
    if (e.event_type === 'ACTION_PROPOSED') return `${p.action_type || ''} tier ${p.tier ?? ''}`;
    if (e.event_type === 'QC_REVIEWED') return `${p.verdict || ''} ${p.outcome || ''}`;
    if (e.event_type === 'ACTION_EXECUTED') return p.settlement_ref || '';
    return Object.keys(p).length ? JSON.stringify(p).slice(0, 80) : '';
  }

  function renderTicker(live) {
    const fresh = [];
    $('ticker').innerHTML = live.events.map((e) => {
      const isNew = !state.firstLoad && !state.seenEvents.has(e.event_id);
      if (isNew) fresh.push(e);
      return `<li class="${isNew ? 'new' : ''}"><span class="tm">${esc(hhmmss(e.occurred_at))}</span>
        <span class="ev ${esc(e.actor_type)}">${esc(e.event_type)}</span>
        <span class="dt">${esc(e.break_id || '')}${e.action_id ? ` #${esc(e.action_id)}` : ''} · ${esc(String(e.actor_id).split(':').pop())} ${esc(describe(e))}</span></li>`;
    }).join('');
    live.events.forEach((e) => state.seenEvents.add(e.event_id));
    fresh.forEach((e) => EVENT_NODE[e.event_type] && flash(EVENT_NODE[e.event_type]));
  }

  async function loadLive() {
    try {
      const live = await api('/api/live');
      state.live = live;
      renderTop(live); renderAgents(live); renderApprovals(live); renderTicker(live);
      state.firstLoad = false;
    } catch (e) { toast(`Live desk: ${e.message}`, true); }
  }
  let liveTimer;
  const refreshLive = () => { clearTimeout(liveTimer); liveTimer = setTimeout(loadLive, 200); };

  // ------------------------------------------------------------ charts (dependency-free SVG)
  const PAL = ['#29B5E8', '#11567F', '#71D3DC', '#7D44CF', '#FF9F36', '#D45B90', '#1E9E6A'];
  const STATUS_COLOR = { NEW: '#71D3DC', CLAIMED: '#29B5E8', PROPOSED: '#7D44CF', REOPENED: '#FF9F36', RESOLVED: '#11567F', ESCALATED: '#D45B90' };

  function hbars(el, items, color) {
    if (!items.length) { el.innerHTML = '<div class="empty">No data yet for this scope.</div>'; return; }
    const W = 420, rowH = 22, H = items.length * rowH + 4, max = Math.max(...items.map((i) => i.v), 1);
    el.innerHTML = `<svg viewBox="0 0 ${W} ${H}">${items.map((it, i) => {
      const w = ((W - 170) * it.v) / max;
      return `<text x="0" y="${i * rowH + 15}">${esc(it.k)}</text>
        <rect x="120" y="${i * rowH + 4}" width="${Math.max(w, 1)}" height="14" rx="3" fill="${color || PAL[i % PAL.length]}"/>
        <text x="${126 + w}" y="${i * rowH + 15}">${esc(it.label ?? fmt(it.v))}</text>`;
    }).join('')}</svg>`;
  }

  function stacked(el, rows) {
    const cust = [...new Set(rows.map((r) => r.custodian))];
    const statuses = Object.keys(STATUS_COLOR).filter((s) => rows.some((r) => r.status === s));
    if (!cust.length) { el.innerHTML = '<div class="empty">No breaks yet for this scope.</div>'; return; }
    const W = 420, rowH = 24, H = cust.length * rowH + 4;
    const tot = Object.fromEntries(cust.map((c) => [c, rows.filter((r) => r.custodian === c).reduce((s, r) => s + Number(r.n), 0)]));
    const max = Math.max(...Object.values(tot), 1);
    let svg = '';
    cust.forEach((c, i) => {
      let x = 120;
      svg += `<text x="0" y="${i * rowH + 16}">${esc(c)}</text>`;
      statuses.forEach((s) => {
        const r = rows.find((q) => q.custodian === c && q.status === s); if (!r) return;
        const w = ((W - 160) * Number(r.n)) / max;
        svg += `<rect x="${x}" y="${i * rowH + 5}" width="${w}" height="15" fill="${STATUS_COLOR[s]}"><title>${esc(s)}: ${esc(r.n)}</title></rect>`;
        x += w;
      });
      svg += `<text x="${x + 6}" y="${i * rowH + 16}">${fmt(tot[c])}</text>`;
    });
    el.innerHTML = `<svg viewBox="0 0 ${W} ${H}">${svg}</svg><div class="legend">${statuses.map((s) => `<span><i style="background:${STATUS_COLOR[s]}"></i>${esc(s)}</span>`).join('')}</div>`;
  }

  function flowChart(el, rows) {
    if (!rows.length) { el.innerHTML = '<div class="empty">No events in the last hour of this scope.</div>'; return; }
    const W = 860, H = 170, L = 30, B = 20, series = [['received', '#29B5E8'], ['proposed', '#7D44CF'], ['executed', '#11567F']];
    const max = Math.max(1, ...rows.flatMap((r) => series.map(([k]) => Number(r[k]))));
    const x = (i) => L + (rows.length === 1 ? (W - L) / 2 : (i * (W - L - 6)) / (rows.length - 1));
    const y = (v) => H - B - ((H - B - 8) * v) / max;
    let svg = `<line x1="${L}" y1="${H - B}" x2="${W}" y2="${H - B}" stroke="#E3E9F0"/>
      <text x="0" y="${y(max) + 4}">${fmt(max)}</text><text x="0" y="${H - B}">0</text>`;
    series.forEach(([k, c]) => {
      const pts = rows.map((r, i) => `${x(i)},${y(Number(r[k]))}`).join(' ');
      svg += `<polyline fill="none" stroke="${c}" stroke-width="2" points="${pts}"/>`;
      rows.forEach((r, i) => { svg += `<circle cx="${x(i)}" cy="${y(Number(r[k]))}" r="2.5" fill="${c}"><title>${esc(k)} ${esc(r[k])}</title></circle>`; });
    });
    const step = Math.max(1, Math.ceil(rows.length / 8));
    rows.forEach((r, i) => { if (i % step === 0) svg += `<text x="${x(i) - 14}" y="${H - 4}">${esc(new Date(r.minute).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false }))}</text>`; });
    el.innerHTML = `<svg viewBox="0 0 ${W} ${H}">${svg}</svg><div class="legend">${series.map(([k, c]) => `<span><i style="background:${c}"></i>${k}</span>`).join('')}</div>`;
  }

  // ------------------------------------------------------------ dashboard
  let lastKpiVals = {};
  function kpiTile(key, k, v, s, cls) {
    const bump = lastKpiVals[key] !== undefined && lastKpiVals[key] !== v;
    lastKpiVals[key] = v;
    return `<div class="kpi ${cls || ''}${bump ? ' bump' : ''}"><div class="k">${esc(k)}</div><div class="v">${esc(v)}</div><div class="s">${esc(s || '')}</div></div>`;
  }

  function renderKpis(d) {
    const sm = d.summary, ac = d.actions, lt = d.latency, q = d.quality, g = d.governance, f = d.freshness;
    const received = num(sm.received) || 0;
    const stp = num(ac.proposed) ? (100 * num(ac.auto_executed)) / num(ac.proposed) : null;
    const pending = state.live ? state.live.pending.length : num(ac.awaiting_human);
    $('kpis').innerHTML = [
      kpiTile('rcv', 'Breaks received', fmt(received), d.scope === 'today' ? 'since desk day opened' : 'all time', 'accent'),
      kpiTile('res', 'Resolved', fmt(sm.resolved), `${received ? fmt((100 * num(sm.resolved)) / received, 0) : 0}% · ${money(sm.resolved_cash)} cleared`, 'good'),
      kpiTile('open', 'Open breaks', fmt(sm.open), `${money(sm.open_cash)} cash at risk · ${fmt(sm.escalated)} escalated`, 'warn'),
      kpiTile('pend', 'Awaiting you', fmt(pending), `${fmt(ac.qc_hold)} on QC hold · ${fmt(ac.rejected)} rejected`),
      kpiTile('claim', 'Receipt → agent', ms(lt.claim_p50_ms), `p50 · p95 ${ms(lt.claim_p95_ms)}`, 'accent'),
      kpiTile('review', 'Agent review time', ms(lt.review_p50_ms), 'p50 claim → proposal'),
      kpiTile('resolve', 'Receipt → settled', ms(lt.resolve_p50_ms), `p50 · p95 ${ms(lt.resolve_p95_ms)}`),
      kpiTile('stp', 'Straight-through', stp === null ? '—' : `${fmt(stp, 0)}%`, `${fmt(ac.auto_executed)} tier-0 auto · ${fmt(ac.human_executed)} human-approved`, 'good'),
    ].join('');

    flowChart($('ch-flow'), d.perMinute);
    stacked($('ch-cust'), d.byCustodian);
    hbars($('ch-mix'), d.actionMix.map((r) => ({ k: r.action_type, v: Number(r.n) })));
    hbars($('ch-ccy'), d.byCurrency.map((r) => ({ k: r.currency, v: Number(r.open_cash), label: `${money(r.open_cash)} · ${fmt(r.n)}` })), '#FF9F36');
    hbars($('ch-age'), [
      { k: '< 5 min', v: num(d.aging.lt5) || 0 }, { k: '5–30 min', v: num(d.aging.m5_30) || 0 }, { k: '> 30 min', v: num(d.aging.gt30) || 0 },
    ], '#71D3DC');

    const lagS = f.live_last_event && f.mirror_last_event ? Math.max(0, (new Date(f.live_last_event) - new Date(f.mirror_last_event)) / 1000) : null;
    const wake = state.live ? state.live.wake.map((w) => Number(w.wake_ms)).filter((n) => !Number.isNaN(n)) : [];
    const wakeMin = wake.length ? Math.min(...wake) : null;
    const acc = num(q.judged) ? (100 * num(q.correct)) / num(q.judged) : null;
    const dbl = num(d.doubleSettle.n) || 0;
    const vp = [
      ['Event-driven wake-up', ms(wakeMin ?? lt.claim_min_ms), `fastest receipt→claim (LISTEN/NOTIFY, no polling) · p50 ${ms(lt.claim_p50_ms)}`, ''],
      ['Zero-ETL mirror', lagS === null ? '—' : `${fmt(lagS, 0)} s behind`, `${fmt(f.mirror_events)} of ${fmt(f.live_events)} ledger rows mirrored · $LIVE reads current`, ''],
      ['Hash-bound approvals', fmt(g.hash_bound_approvals), `${fmt(g.hash_mismatches)} hash mismatches caught · every approval names a user`, 'good'],
      ['QC traps caught', `${fmt(q.traps_held)} / ${fmt(q.traps)}`, 'planted bad proposals held by the independent QC model', num(q.traps) && num(q.traps_held) < num(q.traps) ? 'bad' : 'good'],
      ['Agent accuracy', acc === null ? '—' : `${fmt(acc, 0)}%`, `${fmt(q.correct)} of ${fmt(q.judged)} vs ground truth (break_truth, agents can't read it)`, ''],
      ['Double settlements', fmt(dbl), `idempotency keys · ${fmt(g.kill_blocks)} kill-switch blocks · ${fmt(f.days_closed)} days closed`, dbl ? 'bad' : 'good'],
    ];
    $('vp').innerHTML = vp.map(([k, v, s, c]) => `<div class="vpi"><div class="k">${esc(k)}</div><div class="v ${c}">${esc(v)}</div><div class="s">${esc(s)}</div></div>`).join('');

    $('agent-perf').innerHTML = `<tr><th>Role</th><th>Model</th><th>Runs</th><th>Slots</th><th>LLM p50</th><th>Run avg</th><th>Tokens in / out</th></tr>` +
      (d.agents.map((a) => `<tr><td>${esc(a.agent_role)}</td><td>${esc(a.model)}</td><td>${fmt(a.runs)}</td><td>${fmt(a.slots)}</td>
        <td>${ms(a.llm_p50_ms)}</td><td>${ms(a.run_avg_ms)}</td><td>${fmt(a.input_tokens)} / ${fmt(a.output_tokens)}</td></tr>`).join('') ||
       '<tr><td colspan="7" class="empty">No agent runs in this scope yet.</td></tr>');

    const pm = $('pill-mirror');
    pm.textContent = lagS === null ? 'Mirror —' : `Mirror ${fmt(lagS, 0)}s behind`;
    pm.className = `pill ${lagS !== null && lagS < 90 ? 'ok' : ''}`;
    $('kpi-sub').textContent = `from the Snowflake mirror · ${fmt(d.query_ms)} ms · as of ${hhmmss(d.as_of)}`;
  }

  async function loadKpis() {
    try {
      const d = await api(`/api/kpis?scope=${state.scope}`);
      if (d.scope !== state.scope) return;
      state.kpis = d; renderKpis(d); flash('sf');
    } catch (e) { toast(`Dashboard: ${e.message}`, true); }
  }

  // ------------------------------------------------------------ actions
  document.addEventListener('click', async (ev) => {
    const b = ev.target.closest('button'); if (!b || b.disabled) return;
    try {
      if (b.dataset.add) {
        b.disabled = true;
        const r = await post('/api/breaks', { count: Number(b.dataset.add), trickle: $('trickle').checked });
        toast(r.trickle ? `Replaying ${r.scheduled} DEMO breaks at 1/s` : `Inserted ${r.inserted} breaks`);
        flash('pg');
      } else if (b.dataset.dec) {
        b.disabled = true;
        let note = null;
        if (b.dataset.dec === 'REJECT') { note = prompt('Reason for rejection?'); if (note === null) { b.disabled = false; return; } }
        const r = await post(`/api/actions/${b.dataset.id}/decision`, { decision: b.dataset.dec, sha256: b.dataset.sha, note });
        toast(`Action #${b.dataset.id}: ${r.result}`, r.result !== 'APPROVED' && r.result !== 'REJECTED');
        flash('human');
      } else if (b.dataset.ctl) {
        const en = b.dataset.en === '1';
        if (!en && !confirm(`Kill ${b.dataset.ctl}? It stops claiming and its approved actions are blocked at execution.`)) return;
        await post(`/api/controls/${encodeURIComponent(b.dataset.ctl)}`, { enabled: en });
        toast(`${b.dataset.ctl} ${en ? 'enabled' : 'disabled'}`);
      } else if (b.id === 'btn-bulk') {
        if (!confirm('Approve every eligible action under your name? Each approval is hash-bound and audited; QC-gated actions are skipped.')) return;
        b.disabled = true;
        const r = await post('/api/actions/approve-eligible');
        toast(`Approved ${r.APPROVED} of ${r.considered} · ${r.still_pending} still gated`);
      } else if (b.id === 'btn-close') {
        const note = prompt('Close the desk day? Open breaks go to exceptions (ESCALATED) and open actions expire. Nothing is deleted.\n\nOptional note:', 'EOD roll');
        if (note === null) return;
        b.disabled = true;
        const r = await post('/api/desk-day/close', { note });
        toast(`Day closed: ${r.breaks_carried} breaks carried, ${r.actions_expired} actions expired. Desk day #${r.new_day_id} open.`);
        b.disabled = false;
        loadKpis();
      } else if (b.dataset.scope) {
        state.scope = b.dataset.scope; lastKpiVals = {};
        document.querySelectorAll('#scope button').forEach((x) => x.classList.toggle('on', x === b));
        loadKpis();
      }
    } catch (e) { toast(e.message, true); }
    finally { if (b.dataset.add || b.id === 'btn-close') b.disabled = false; refreshLive(); }
  });

  // ------------------------------------------------------------ realtime
  function connectStream() {
    const es = new EventSource('/api/stream');
    const pl = $('pill-listen');
    es.addEventListener('listen', (m) => { const up = JSON.parse(m.data).up; pl.className = `pill ${up ? 'ok' : 'bad'}`; });
    es.addEventListener('pg', (m) => {
      const d = JSON.parse(m.data);
      if (CHANNEL_NODE[d.channel]) flash(CHANNEL_NODE[d.channel]);
      if (d.channel === 'desk_day') loadKpis();
      refreshLive();
    });
    es.addEventListener('sim', () => flash('pg'));
    es.onerror = () => { pl.className = 'pill bad'; };
  }

  api('/api/me').then((m) => { $('pill-user').textContent = m.user; }).catch(() => { $('pill-user').textContent = 'not signed in'; });
  loadLive(); loadKpis(); connectStream();
  setInterval(loadLive, 5000);    // fallback; NOTIFY drives most refreshes
  setInterval(loadKpis, 15000);   // matches server cache TTL and mirror refresh cadence
})();
