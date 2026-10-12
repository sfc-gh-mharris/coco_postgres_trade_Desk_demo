"""DESK_SIM: replays break scenarios from BREAK_DESK.REF.BREAK_SCENARIOS into the Postgres queue.

Runs as a job service owned by DESK_SERVICE_ROLE (the only role that can read the scenario catalog)
and logs in to Postgres as desk_sim, whose only privilege is desk.insert_break. Ground truth goes
to desk.break_truth, which no agent role can read.

Env: BATCH (EVAL | QC | DEMO), LIMIT, RATE_PER_S (0 = as fast as possible), ID_SUFFIX (optional,
appended to break_id so a batch can be replayed).
"""
from __future__ import annotations

import json
import logging
import os
import time

from common import DESK_DB, pg_connect, sf_connect

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("sim")

BATCH = os.environ.get("BATCH", "EVAL")
LIMIT = int(os.environ.get("LIMIT", "1000"))
RATE = float(os.environ.get("RATE_PER_S", "0"))
SUFFIX = os.environ.get("ID_SUFFIX", "")


def main():
    sf = sf_connect()
    cur = sf.cursor()
    cur.execute(f"""SELECT BREAK_ID, TRADE_REF, CUSTODIAN, COUNTERPARTY_ID, ISIN, CURRENCY, SETTLE_DATE::STRING AS SETTLE_DATE,
                          CUSTODIAN_MESSAGE, QTY_DIFF, PRICE_DIFF_BPS, CASH_DIFF, PRIORITY, EXPECTED_ACTION,
                          SCENARIO, IS_QC_TRAP
                   FROM {DESK_DB}.REF.BREAK_SCENARIOS WHERE BATCH = %s ORDER BY BREAK_ID LIMIT %s""",
                (BATCH, LIMIT))
    cols = [c[0].lower() for c in cur.description]
    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    log.info("replaying %s %s breaks at %s/s", len(rows), BATCH, RATE or "max")
    inserted = 0
    with pg_connect() as pg:
        for r in rows:
            brk = {k: r[k] for k in ("trade_ref", "custodian", "counterparty_id", "isin", "currency", "settle_date",
                                     "custodian_message", "priority")}
            brk.update(break_id=r["break_id"] + SUFFIX, qty_diff=float(r["qty_diff"]),
                       price_diff_bps=float(r["price_diff_bps"]), cash_diff=float(r["cash_diff"]))
            truth = {"expected_action": r["expected_action"], "scenario": r["scenario"], "is_qc_trap": r["is_qc_trap"]}
            pg.execute("SELECT desk.insert_break(%s, %s)", (json.dumps(brk), json.dumps(truth)))
            inserted += 1
            if RATE > 0:
                time.sleep(1 / RATE)
    print(f"SIM_RESULT {json.dumps({'batch': BATCH, 'inserted': inserted})}", flush=True)


if __name__ == "__main__":
    main()
