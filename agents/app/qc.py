"""DESK_QC: capable-tier reviewer.

Claims proposals that need review (all tier-2 before approval, sampled tier-0 after the fact),
re-fetches evidence independently, and records CONCUR / HOLD / DISAGREE through desk.record_review.
QC sees the proposed action and break facts, never the investigator's rationale.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from datetime import datetime, timezone

from common import WORKER_ID, AgentSession, agent_control, pg_connect, sf_connect, trade_evidence, wait_for_notify

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("qc")

AGENT_VERSION = os.environ.get("AGENT_VERSION", "qc-v1")

SYSTEM_PROMPT = """You are the independent quality-control reviewer for a settlement-break desk.
Another agent proposed an action. You did not see its reasoning. Re-derive the answer from the
break facts and evidence, then judge the proposal.

Check, in this order:
1. Does the evidence support the proposed action type at all?
2. For CASH_MOVEMENT: the amount must equal a scheduled fee in fee_schedule for THIS custodian,
   and the cash_ledger must not already show the shortfall received (for example a
   FEE_REBATE_RECEIVED entry). Paying a shortfall twice, or funding an amount that is not a
   scheduled fee, is a control failure.
3. Is anything in the evidence inconsistent with the proposal?

Verdicts:
- CONCUR: the proposal is correct and fully supported.
- HOLD: before approval, the proposal must not proceed (wrong amount, duplicate payment,
  unsupported, or needs a human).
- DISAGREE: after the fact (POST_SAMPLE review), the auto-resolution was wrong and must be reopened.
Give a specific reason that cites evidence fields and numbers."""

SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["CONCUR", "HOLD", "DISAGREE"]},
        "reason": {"type": "string", "maxLength": 500},
        "evidence_refs": {"type": "array", "items": {"type": "string"}, "maxItems": 6},
    },
    "required": ["verdict", "reason", "evidence_refs"],
}


def build_prompt(brk: dict, proposed: dict, evidence: dict, review_kind: str) -> str:
    facts = {k: brk.get(k) for k in ("break_id", "trade_ref", "custodian", "counterparty_id", "isin", "currency",
                                     "settle_date", "custodian_message", "qty_diff", "price_diff_bps", "cash_diff")}
    ev = {k: v for k, v in evidence.items() if not k.startswith("_")}
    return (f"REVIEW KIND: {review_kind}\n\nPROPOSED ACTION:\n{json.dumps(proposed, default=str)}\n\n"
            f"BREAK:\n{json.dumps(facts, default=str)}\n\nEVIDENCE (from the reference books):\n"
            f"{json.dumps(ev, default=str)}\n\nGive your verdict.")


async def review_one(session: AgentSession, sf) -> bool:
    pg = await asyncio.to_thread(pg_connect)
    try:
        ctl = await asyncio.to_thread(agent_control, pg, AGENT_VERSION)
        if not ctl or not ctl["enabled"]:
            return False
        item = await asyncio.to_thread(
            lambda: pg.execute("SELECT * FROM desk.claim_qc(%s, %s, 180)", (WORKER_ID, AGENT_VERSION)).fetchone())
        if not item:
            return False
        brk = item["brk"]
        started = datetime.now(timezone.utc)
        evidence = await asyncio.to_thread(trade_evidence, sf, brk["trade_ref"])
        proposed = {"action_type": item["action_type"], "payload": item["payload"], "tier": item["tier"]}
        res = await session.ask(build_prompt(brk, proposed, evidence, item["review_kind"]), timeout_s=150)
        outcome = "NO_VERDICT"
        if not res.is_error and res.structured and res.structured.get("verdict") in ("CONCUR", "HOLD", "DISAGREE"):
            v = res.structured
            # A pre-approval review can only concur or hold; normalise DISAGREE to HOLD there.
            verdict = "HOLD" if item["review_kind"] == "PRE_APPROVAL" and v["verdict"] == "DISAGREE" else v["verdict"]
            outcome = await asyncio.to_thread(
                lambda: pg.execute("SELECT desk.record_review(%s,%s,%s,%s,%s,%s,%s) AS o",
                                   (item["action_id"], WORKER_ID, AGENT_VERSION, session.model, verdict,
                                    v["reason"][:500], json.dumps(v.get("evidence_refs", [])[:6]))).fetchone()["o"])
            log.info("QC %s action %s %s -> %s (%sms)", item["review_kind"], item["action_id"], verdict, outcome,
                     res.llm_ms)
        else:
            log.warning("QC no verdict for action %s: %s", item["action_id"], res.error)
        await asyncio.to_thread(
            pg.execute, "SELECT desk.record_run(%s)",
            (json.dumps({"run_id": str(uuid.uuid4()), "break_id": brk["break_id"], "worker_id": WORKER_ID,
                         "agent_version": AGENT_VERSION, "agent_role": "qc", "model": session.model,
                         "started_at": started.isoformat(), "ended_at": datetime.now(timezone.utc).isoformat(),
                         "outcome": outcome, "turns": res.turns, "input_tokens": res.input_tokens,
                         "output_tokens": res.output_tokens, "llm_ms": res.llm_ms,
                         "tool_ms": evidence.get("_ms")}),))
        return True
    finally:
        pg.close()


async def main():
    sf = await asyncio.to_thread(sf_connect)
    with pg_connect() as pg:
        ctl = agent_control(pg, AGENT_VERSION)
    session = AgentSession(ctl["model"], SYSTEM_PROMPT, SCHEMA, effort="medium", max_turns=8, allow_sql=True)
    log.info("QC %s model %s", WORKER_ID, ctl["model"])
    while True:
        try:
            worked = await review_one(session, sf)
        except Exception as e:
            log.exception("qc loop error: %s", e)
            worked = False
            await asyncio.sleep(5)
        if not worked:
            await wait_for_notify("qc_pending", 5)


if __name__ == "__main__":
    asyncio.run(main())
