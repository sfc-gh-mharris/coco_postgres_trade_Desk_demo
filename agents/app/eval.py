"""Model accuracy bake-off (Stage 1c, completed with real prompts and evidence).

MODE=investigator: runs the investigator prompt over the EVAL batch for each model in MODELS and
compares to BREAK_SCENARIOS.EXPECTED_ACTION.
MODE=qc: runs the QC prompt over the QC batch (4 planted errors) for each model.
Runs as DESK_SERVICE_ROLE (reads the ground-truth catalog); it does not touch Postgres.
"""
from __future__ import annotations

import asyncio
import json
import os
import time

from common import DESK_DB, AgentSession, sf_connect, trade_evidence

MODE = os.environ.get("MODE", "investigator")
MODELS = [m for m in os.environ["MODELS"].split(",") if m]


def load_batch(sf, batch: str) -> list[dict]:
    cur = sf.cursor()
    cur.execute(f"""SELECT BREAK_ID, TRADE_REF, CUSTODIAN, COUNTERPARTY_ID, ISIN, CURRENCY, SETTLE_DATE,
                          CUSTODIAN_MESSAGE, QTY_DIFF, PRICE_DIFF_BPS, CASH_DIFF, SCENARIO, EXPECTED_ACTION,
                          IS_QC_TRAP
                   FROM {DESK_DB}.REF.BREAK_SCENARIOS WHERE BATCH = %s ORDER BY BREAK_ID""", (batch,))
    cols = [c[0].lower() for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


async def run_investigator(sf, rows):
    import worker
    for model in MODELS:
        s = AgentSession(model, worker.SYSTEM_PROMPT, worker.SCHEMA, effort="low", max_turns=4, allow_sql=True)
        correct, times, details = 0, [], []
        for r in rows:
            ev = await asyncio.to_thread(trade_evidence, sf, r["trade_ref"])
            t0 = time.time()
            res = await s.ask(worker.build_prompt(r, ev))
            dt = round(time.time() - t0, 2)
            got = (res.structured or {}).get("action_type")
            ok = got == r["expected_action"]
            correct += ok
            times.append(dt)
            details.append({"id": r["break_id"], "scenario": r["scenario"], "expected": r["expected_action"],
                            "got": got, "s": dt, "tools": res.tools_used, "err": res.error})
        await s.close()
        times_sorted = sorted(times)
        print("EVAL_RESULT " + json.dumps({
            "mode": MODE, "model": model, "correct": correct, "n": len(rows),
            "p50_s": times_sorted[len(times) // 2], "max_s": max(times), "details": details}), flush=True)


async def run_qc(sf, rows):
    import qc
    for model in MODELS:
        s = AgentSession(model, qc.SYSTEM_PROMPT, qc.SCHEMA, effort="medium", max_turns=8, allow_sql=True)
        caught, false_holds, times, details = 0, 0, [], []
        for r in rows:
            ev = await asyncio.to_thread(trade_evidence, sf, r["trade_ref"])
            proposed = {"action_type": "CASH_MOVEMENT",
                        "payload": {"amount": float(r["cash_diff"]), "currency": r["currency"],
                                    "beneficiary": r["custodian"]}}
            t0 = time.time()
            res = await s.ask(qc.build_prompt(r, proposed, ev, "PRE_APPROVAL"))
            dt = round(time.time() - t0, 2)
            verdict = (res.structured or {}).get("verdict")
            if r["is_qc_trap"]:
                caught += verdict in ("HOLD", "DISAGREE")
            else:
                false_holds += verdict != "CONCUR"
            times.append(dt)
            details.append({"id": r["break_id"], "scenario": r["scenario"], "trap": r["is_qc_trap"],
                            "verdict": verdict, "s": dt, "reason": (res.structured or {}).get("reason", "")[:160],
                            "err": res.error})
        await s.close()
        print("EVAL_RESULT " + json.dumps({
            "mode": MODE, "model": model, "traps_caught": caught, "traps": sum(r["is_qc_trap"] for r in rows),
            "false_holds": false_holds, "p50_s": sorted(times)[len(times) // 2], "details": details}), flush=True)


async def main():
    sf = await asyncio.to_thread(sf_connect)
    if MODE == "investigator":
        await run_investigator(sf, load_batch(sf, "EVAL"))
    else:
        await run_qc(sf, load_batch(sf, "QC"))


if __name__ == "__main__":
    asyncio.run(main())
