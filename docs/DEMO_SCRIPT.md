# Demo script (about 15 minutes)

Before you start:
- Run `./demo.sh status`; everything should be READY.
- If the desk has leftovers from a previous session, run `./demo.sh close-day`, or use **Close day** in the Node app, for a clean "next morning".

## 1. The flood

**Show:** event-driven agents and the scale-out queue.

- **Node app:** click **+25** with *trickle* on.
  - Watch the architecture strip light up.
  - Agent tiles switch to *working*.
  - Approval cards slide in.
  - The **Receipt → agent** KPI sits in the tens of milliseconds.
- **Streamlit or CLI:** run `./demo.sh seed 25 2`.

**Talking points:**
- Postgres `LISTEN/NOTIFY` wakes the agents; there is no polling.
- `FOR UPDATE SKIP LOCKED` leases let each worker slot take one break at a time.
- Tier-0 price breaks within tolerance are auto-executed by policy, not by the model.

## 2. Human in the loop

**Show:** tier-2 cash needs independent QC plus a named human, and the approval is bound to what the human saw.

1. Open a `CASH_MOVEMENT` card. It shows three things:
   - the investigator's rationale
   - QC's independent verdict, from a different model that never sees the investigator's reasoning
   - the payload SHA-256
2. Click **Approve**. The executor settles it within a second, and the ledger shows `ACTION_APPROVED` with your Snowflake user, then `ACTION_EXECUTED`.

## 3. The canary regression

**Show:** QC catches a bad prompt before money moves.

```bash
./demo.sh canary on         # routes new work to investigator-v3 (a "simplified" cash rule)
./demo.sh seed 10 2 QC      # the QC batch contains 4 planted traps
```

- The canary proposes cash for all 10 breaks.
- QC holds the 4 traps: 2 duplicate payments (a rebate was already received) and 2 non-scheduled fees. Their cards show **QC hold — approval blocked**.
- Run `./demo.sh canary off` to restore the default.

## 4. The kill switch beats a prior approval

```bash
./demo.sh executor pause
```

1. Approve one concurred cash movement.
2. Click **Kill** on its agent version, in the Node agents panel or the Streamlit Agent controls tab.
3. Run `./demo.sh executor resume`.

The approved action becomes `BLOCKED_BY_KILL_SWITCH`: execution re-checks the kill switch, so a prior approval is not enough. Re-enable the agent afterwards.

## 5. Analytics on live operational data (no ETL)

- **Node dashboard (right side):**
  - KPIs, flow per minute, custodian mix and aging, all read from the mirror.
  - The "Why this architecture" tiles show mirror lag, hash-bound approvals, QC traps caught, accuracy against ground truth, and double settlements (0).
- **Snowsight:** open the rendered `build/sql/mirror_analytics.sql`. It holds 17 read-only queries over the base, `$LIVE` and `$CHANGES` views.

## 6. Flight recorder

In Snowflake Intelligence / CoWork, open `DESK_FLIGHT_RECORDER` and ask:
- "Show the full timeline for break EVAL-0001"
- "Which proposals did QC hold or disagree with, and why?"
- "When was the kill switch used, by whom, and what did it block?"
- "How many runs, how much latency, and how many tokens per agent version and model?"

The archive task runs every 5 minutes. To refresh immediately, run `CALL <PREFIX>.AUDIT.ARCHIVE_DESK();`.

## 7. Clean slate for the next audience

Either click **Approve all eligible** then **Close day** in the Node app, or run `./demo.sh close-day`:
- Open breaks move to exceptions (ESCALATED) and open actions expire.
- Agents still holding a break are fenced out.
- Nothing is deleted, and the KPI "Today" scope starts fresh.

Run `./demo.sh pause` when you are done.
