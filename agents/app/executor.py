"""DESK_EXECUTOR: the only component that can execute actions.

Logs in to Postgres as desk_exec, whose only privileges are desk.ready_actions and
desk.execute_action. execute_action re-checks the kill switch, approval, QC concurrence, expiry,
and idempotency at the moment of execution, so an approval granted earlier cannot outrun a kill.
Executed actions are recorded in BREAK_DESK.REF.SIM_SETTLEMENT_LOG with MERGE on the idempotency key.
"""
from __future__ import annotations

import asyncio
import json
import logging

from common import DESK_DB, WORKER_ID, pg_connect, sf_connect, wait_for_notify

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("executor")

MERGE_SQL = f"""MERGE INTO {DESK_DB}.REF.SIM_SETTLEMENT_LOG t
USING (SELECT %(key)s AS IDEMPOTENCY_KEY, %(action_id)s AS ACTION_ID, %(break_id)s AS BREAK_ID,
              %(action_type)s AS ACTION_TYPE, PARSE_JSON(%(payload)s) AS PAYLOAD) s
ON t.IDEMPOTENCY_KEY = s.IDEMPOTENCY_KEY
WHEN NOT MATCHED THEN INSERT (IDEMPOTENCY_KEY, ACTION_ID, BREAK_ID, ACTION_TYPE, PAYLOAD)
VALUES (s.IDEMPOTENCY_KEY, s.ACTION_ID, s.BREAK_ID, s.ACTION_TYPE, s.PAYLOAD)"""


def drain(pg, sf) -> int:
    ids = [r["a"] for r in pg.execute("SELECT a FROM desk.ready_actions(50) a").fetchall()]
    for action_id in ids:
        res = pg.execute("SELECT desk.execute_action(%s, %s) AS r", (action_id, WORKER_ID)).fetchone()["r"]
        log.info("action %s -> %s", action_id, res.get("result"))
        if res.get("result") == "EXECUTED":
            receipt = res["receipt"]
            key = receipt["settlement_ref"].removeprefix("SIM-")
            sf.cursor().execute(MERGE_SQL, {"key": key, "action_id": action_id, "break_id": key.split(":")[0],
                                            "action_type": receipt["action_type"], "payload": json.dumps(receipt)})
    return len(ids)


async def main():
    sf = await asyncio.to_thread(sf_connect)
    pg = await asyncio.to_thread(pg_connect)
    log.info("executor %s started", WORKER_ID)
    while True:
        try:
            n = await asyncio.to_thread(drain, pg, sf)
        except Exception as e:
            log.exception("executor error: %s", e)
            pg.close()
            await asyncio.sleep(5)
            pg = await asyncio.to_thread(pg_connect)
            n = 0
        if n == 0:
            await wait_for_notify("actions_approved", 5)


if __name__ == "__main__":
    asyncio.run(main())
