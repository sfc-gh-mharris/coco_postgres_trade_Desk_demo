"""DESK_WORKER: fast-tier investigator.

Loop: claim a break (SKIP LOCKED lease) -> fetch the evidence bundle from Snowflake in one query
-> one SDK turn on a fast model -> schema-validated decision -> desk.propose_action. Tier, routing,
and fencing are decided by Postgres, not by the model.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

from common import (WORKER_ID, AgentSession, agent_control, heartbeat_loop, pg_connect, sf_connect,
                    trade_evidence, wait_for_notify)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("worker")

AGENT_VERSION = os.environ.get("AGENT_VERSION", "investigator-v1")
CONCURRENCY = int(os.environ.get("WORKER_CONCURRENCY", "2"))
IDLE_SWEEP_S = 5

ACTIONS = ["ACCEPT_PRICE_DIFF", "REQUEST_SSI_UPDATE", "BOOK_QTY_ADJUSTMENT", "CASH_MOVEMENT", "ESCALATE"]

_PREAMBLE = """You are a T+1 settlement-break investigator at a custodian operations desk.
You receive one break and an evidence bundle from the firm's books. Decide the single next action.

Decision rules, checked in this order:
1. Price break (price_diff_bps != 0):
   - |price_diff_bps| <= 5: rounding. ACCEPT_PRICE_DIFF.
   - Otherwise compare prices[]: if the EOD_VENDOR price equals the CUSTODIAN price, the custodian is
     right: ACCEPT_PRICE_DIFF. If the EOD_VENDOR price equals our trade.PRICE, it is a dispute: ESCALATE.
2. Settlement-instruction failure (message mentions BIC, agent, account, DK, or unmatched): if
   ssi_history has a record with EFFECTIVE_FROM on or before trade SETTLE_DATE that replaced the one
   we used (an older record now has EFFECTIVE_TO set): REQUEST_SSI_UPDATE.
3. Quantity break (qty_diff != 0): if a CANCELLED allocation's QTY equals |qty_diff| and the ACTIVE
   allocations sum to the custodian quantity: BOOK_QTY_ADJUSTMENT.
"""
_CASH_STRICT = """4. Cash break (cash_diff != 0): CASH_MOVEMENT only if cash_diff equals a SETTLEMENT_FEE amount in
   fee_schedule for this custodian AND cash_ledger has no FEE_REBATE_RECEIVED entry. Otherwise ESCALATE.
"""
# Staged regression for the canary demo: a plausible-looking simplification that drops the fee
# match and duplicate-payment checks. QC is expected to catch what this lets through.
_CASH_LOOSE = """4. Cash break (cash_diff != 0): if the custodian message says standard charges were applied,
   fund the shortfall with CASH_MOVEMENT. Otherwise ESCALATE.
"""
_TAIL = """5. Anything else, vague messages, or conflicting evidence: ESCALATE.

Decide from the evidence only. Cite the evidence keys you relied on. Be brief.
The evidence bundle is complete; answer immediately without running SQL unless a key is missing."""

PROMPTS = {
    "inv-p2": _PREAMBLE + _CASH_STRICT + _TAIL,
    "inv-p3-loose": _PREAMBLE + _CASH_LOOSE + _TAIL,
}
SYSTEM_PROMPT = PROMPTS["inv-p2"]

SCHEMA = {
    "type": "object",
    "properties": {
        "action_type": {"type": "string", "enum": ACTIONS},
        "rationale": {"type": "string", "maxLength": 400},
        "evidence_refs": {"type": "array", "items": {"type": "string"}, "maxItems": 6},
        "amount": {"type": "number"},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
    },
    "required": ["action_type", "rationale", "evidence_refs", "confidence"],
}


def build_prompt(brk: dict, evidence: dict) -> str:
    facts = {k: brk[k] for k in ("break_id", "trade_ref", "custodian", "counterparty_id", "isin", "currency",
                                 "settle_date", "custodian_message", "qty_diff", "price_diff_bps", "cash_diff")}
    ev = {k: v for k, v in evidence.items() if not k.startswith("_")}
    return ("BREAK:\n" + json.dumps(facts, default=str) + "\n\nEVIDENCE (from the reference books):\n"
            + json.dumps(ev, default=str) + "\n\nDecide the action.")


def build_payload(brk: dict, decision: dict) -> dict:
    """Deterministic payload: the amount comes from the break, not from the model."""
    p = {"break_id": brk["break_id"], "trade_ref": brk["trade_ref"], "action_type": decision["action_type"]}
    if decision["action_type"] == "CASH_MOVEMENT":
        p.update(amount=float(brk["cash_diff"]), currency=brk["currency"], beneficiary=brk["custodian"])
    elif decision["action_type"] == "BOOK_QTY_ADJUSTMENT":
        p.update(qty_adjustment=float(brk["qty_diff"]))
    elif decision["action_type"] == "ACCEPT_PRICE_DIFF":
        p.update(price_diff_bps=float(brk["price_diff_bps"]))
    return p


async def process_one(slot: int, session: AgentSession, sf) -> bool:
    pg = await asyncio.to_thread(pg_connect)
    try:
        ctl = await asyncio.to_thread(agent_control, pg, AGENT_VERSION)
        if not ctl or not ctl["enabled"]:
            return False
        if ctl["model"] != session.model or PROMPTS[ctl["prompt_version"]] != session.options.system_prompt:
            log.info("control changed for %s: model %s, prompt %s", AGENT_VERSION, ctl["model"],
                     ctl["prompt_version"])
            await session.close()
            session.model = ctl["model"]
            session.options.model = ctl["model"]
            session.options.system_prompt = PROMPTS[ctl["prompt_version"]]
        worker = f"{WORKER_ID}#{slot}"
        brk = await asyncio.to_thread(
            lambda: pg.execute("SELECT * FROM desk.claim_break(%s, %s, 90)", (worker, AGENT_VERSION)).fetchone())
        if not brk:
            return False

        run_id = str(uuid.uuid4())
        started = datetime.now(timezone.utc)
        fence = brk["fence_token"]
        stop = asyncio.Event()
        hb = asyncio.create_task(heartbeat_loop(pg_connect, brk["break_id"], fence, stop))
        outcome, res, evidence = "ERROR", None, {}
        try:
            evidence = await asyncio.to_thread(trade_evidence, sf, brk["trade_ref"])
            res = await session.ask(build_prompt(brk, evidence))
            if res.is_error or not res.structured or res.structured.get("action_type") not in ACTIONS:
                log.warning("%s no valid decision: %s", brk["break_id"], res.error)
                await asyncio.to_thread(
                    pg.execute, "SELECT desk.record_finding(%s,%s,%s,%s,%s,%s,%s)",
                    (brk["break_id"], fence, run_id, worker, AGENT_VERSION, session.model,
                     json.dumps({"error": res.error or "invalid structured output"})))
                outcome = "NO_DECISION"
                return True
            d = res.structured
            await asyncio.to_thread(
                pg.execute, "SELECT desk.record_finding(%s,%s,%s,%s,%s,%s,%s)",
                (brk["break_id"], fence, run_id, worker, AGENT_VERSION, session.model,
                 json.dumps({"evidence_query_id": evidence.get("_query_id"), "evidence_ms": evidence.get("_ms"),
                             "llm_ms": res.llm_ms, "confidence": d.get("confidence"),
                             "tools_used": res.tools_used})))
            action = await asyncio.to_thread(
                lambda: pg.execute(
                    "SELECT (a).action_id, (a).status, (a).tier FROM (SELECT desk.propose_action("
                    "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) AS a) s",
                    (brk["break_id"], fence, run_id, worker, AGENT_VERSION, session.model, d["action_type"],
                     json.dumps(build_payload(brk, d)), d["rationale"][:400],
                     json.dumps(d.get("evidence_refs", [])[:6]))).fetchone())
            outcome = f"PROPOSED:{d['action_type']}:{action['status']}"
            log.info("%s %s -> %s tier %s (%sms llm, %sms evidence)", worker, brk["break_id"],
                     d["action_type"], action["tier"], res.llm_ms, evidence.get("_ms"))
            return True
        except Exception as e:  # stale fence or transient failure: lease expiry hands the break on
            log.warning("%s failed on %s: %s", worker, brk["break_id"], str(e).splitlines()[0][:200])
            return True
        finally:
            stop.set()
            await hb
            run = {"run_id": run_id, "break_id": brk["break_id"], "worker_id": worker,
                   "agent_version": AGENT_VERSION, "agent_role": "investigator", "model": session.model,
                   "started_at": started.isoformat(), "ended_at": datetime.now(timezone.utc).isoformat(),
                   "outcome": outcome, "tool_ms": evidence.get("_ms")}
            if res is not None:
                run.update(turns=res.turns, input_tokens=res.input_tokens, output_tokens=res.output_tokens,
                           llm_ms=res.llm_ms)
            await asyncio.to_thread(pg.execute, "SELECT desk.record_run(%s)", (json.dumps(run),))
    finally:
        pg.close()


async def slot_loop(slot: int):
    sf = await asyncio.to_thread(sf_connect)
    with pg_connect() as pg:
        ctl = agent_control(pg, AGENT_VERSION)
    session = AgentSession(ctl["model"], PROMPTS[ctl["prompt_version"]], SCHEMA, effort="low", max_turns=4,
                           allow_sql=True)
    while True:
        try:
            worked = await process_one(slot, session, sf)
        except Exception as e:
            log.exception("slot %s loop error: %s", slot, e)
            worked = False
            await asyncio.sleep(5)
        if not worked:
            await wait_for_notify("breaks_new", IDLE_SWEEP_S)


async def main():
    log.info("worker %s version %s concurrency %s", WORKER_ID, AGENT_VERSION, CONCURRENCY)
    await asyncio.gather(*(slot_loop(i) for i in range(CONCURRENCY)))


if __name__ == "__main__":
    asyncio.run(main())
