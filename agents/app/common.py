"""Shared runtime for BREAK_DESK agents in SPCS: Postgres access, Snowflake evidence, SDK sessions.

Authentication: Snowflake generates SNOWFLAKE_HOME/connections.toml (sessionTokenConfig.
mountConnectionConfig) with token_file_path, which both the Cortex Code CLI and the Python
connector read. See docs/auth-decision.md.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import socket
import time
from dataclasses import dataclass, field

import psycopg
import snowflake.connector
from psycopg.rows import dict_row

from cortex_code_agent_sdk import (
    AssistantMessage, CortexCodeAgentOptions, CortexCodeSDKClient, ResultMessage, ToolUseBlock,
)

log = logging.getLogger("desk")
PG_HOST = os.environ.get("PGHOST", "")
PG_CA = os.environ.get("PG_CA", "/secrets/pg_ca/secret_string")
DESK_DB = os.environ.get("DESK_DB", "BREAK_DESK")
WORKER_ID = f"{os.environ.get('SERVICE_NAME', 'desk')}:{socket.gethostname()}"


def _secret(name: str) -> str:
    with open(f"/secrets/pg/{name}") as f:
        return f.read().strip()


def pg_connect(autocommit: bool = True) -> psycopg.Connection:
    return psycopg.connect(
        host=PG_HOST, port=5432, dbname="postgres", user=_secret("username"),
        password=_secret("password"), sslmode="verify-full", sslrootcert=PG_CA,
        connect_timeout=15, application_name=WORKER_ID[:60], autocommit=autocommit,
        row_factory=dict_row,
    )


def _sf_new() -> snowflake.connector.SnowflakeConnection:
    return snowflake.connector.connect(connection_name="default",
                                       warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "DESK_WH"))


# SPCS rotates the session token file; a connection opened at startup dies after a few hours with
# 390114. Reconnect (re-reading the token) and retry once instead of failing every break.
_TOKEN_EXPIRED = {390111, 390112, 390114}


class _RetryCursor:
    def __init__(self, owner: "SfConn"):
        self._owner, self._cur = owner, owner.conn.cursor()

    def execute(self, *args, **kwargs):
        try:
            return self._cur.execute(*args, **kwargs)
        except snowflake.connector.errors.DatabaseError as e:
            if getattr(e, "errno", None) not in _TOKEN_EXPIRED:
                raise
            log.info("snowflake token expired; reconnecting")
            self._owner.reconnect()
            self._cur = self._owner.conn.cursor()
            return self._cur.execute(*args, **kwargs)

    def __getattr__(self, name):
        return getattr(self._cur, name)


class SfConn:
    def __init__(self):
        self.conn = _sf_new()

    def reconnect(self):
        try:
            self.conn.close()
        except Exception:
            pass
        self.conn = _sf_new()

    def cursor(self) -> _RetryCursor:
        return _RetryCursor(self)

    def __getattr__(self, name):
        return getattr(self.conn, name)


def sf_connect() -> SfConn:
    return SfConn()


def trade_evidence(sf, trade_ref: str) -> dict:
    t0 = time.time()
    cur = sf.cursor()
    cur.execute(f"SELECT {DESK_DB}.REF.TRADE_EVIDENCE(%s)", (trade_ref,))
    row = cur.fetchone()
    evidence = json.loads(row[0]) if row and row[0] else {}
    evidence["_query_id"] = cur.sfqid
    evidence["_ms"] = round((time.time() - t0) * 1000)
    return evidence


def agent_control(pg, version: str) -> dict | None:
    return pg.execute("SELECT * FROM desk.agent_controls WHERE agent_version = %s", (version,)).fetchone()


@dataclass
class TurnResult:
    structured: dict | None = None
    is_error: bool = True
    turns: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    llm_ms: int = 0
    tool_ms: int = 0
    tools_used: list[str] = field(default_factory=list)
    error: str | None = None


class AgentSession:
    """A persistent SDK client (one CLI process). Recycled after `max_uses` turns so the
    conversation context, and therefore per-turn input, stays small."""

    def __init__(self, model: str, system_prompt: str, schema: dict, effort: str, max_turns: int,
                 allow_sql: bool, max_uses: int = 8):
        self.model, self.max_uses, self.uses = model, max_uses, 0
        self.options = CortexCodeAgentOptions(
            cwd="/tmp", model=model, setting_sources=[], effort=effort, max_turns=max_turns,
            system_prompt=system_prompt,
            allowed_tools=["SQL"] if allow_sql else [],
            disallowed_tools=["Bash", "Write", "Edit", "Read", "Glob", "Grep"] + ([] if allow_sql else ["SQL"]),
            output_format={"type": "json_schema", "schema": schema},
        )
        self.client: CortexCodeSDKClient | None = None

    async def _ensure(self):
        if self.client is None or self.uses >= self.max_uses:
            await self.close()
            self.client = CortexCodeSDKClient(self.options)
            await self.client.connect()
            self.uses = 0

    async def close(self):
        if self.client is not None:
            try:
                await self.client.disconnect()
            except Exception:  # process may already be gone; nothing to recover
                pass
            self.client = None

    async def ask(self, prompt: str, timeout_s: float = 90) -> TurnResult:
        await self._ensure()
        self.uses += 1
        res = TurnResult()
        t0 = time.time()
        tool_started: float | None = None
        try:
            await self.client.query(prompt)
            async with asyncio.timeout(timeout_s):
                async for msg in self.client.receive_response():
                    if isinstance(msg, AssistantMessage):
                        for b in msg.content:
                            if isinstance(b, ToolUseBlock) and b.name != "StructuredOutput":
                                res.tools_used.append(b.name)
                                tool_started = time.time()
                    elif tool_started is not None:
                        res.tool_ms += round((time.time() - tool_started) * 1000)
                        tool_started = None
                    if isinstance(msg, ResultMessage):
                        usage = msg.usage or {}
                        res.structured = msg.structured_output
                        res.is_error = msg.is_error or not isinstance(msg.structured_output, dict)
                        res.turns = msg.num_turns
                        res.input_tokens = int(usage.get("input_tokens", 0)) + int(
                            usage.get("cache_read_input_tokens", 0))
                        res.output_tokens = int(usage.get("output_tokens", 0))
                        if msg.is_error:
                            res.error = f"{msg.subtype}: {(msg.result or '')[:200]}"
        except Exception as e:  # surface the failure; the break's lease expires and it is reclaimed
            res.error = f"{type(e).__name__}: {e}"[:300]
            await self.close()
        res.llm_ms = max(0, round((time.time() - t0) * 1000) - res.tool_ms)
        return res


async def heartbeat_loop(pg_factory, break_id: str, fence: int, stop: asyncio.Event, every_s: int = 30):
    pg = await asyncio.to_thread(pg_factory)
    try:
        while not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), timeout=every_s)
            except TimeoutError:
                ok = await asyncio.to_thread(
                    lambda: pg.execute("SELECT desk.heartbeat(%s, %s, 90) AS ok", (break_id, fence)).fetchone()["ok"])
                if not ok:
                    log.warning("lease lost for %s fence %s", break_id, fence)
                    return
    finally:
        pg.close()


async def wait_for_notify(channel: str, timeout_s: float) -> None:
    """Block until a NOTIFY on `channel` or the timeout. NOTIFY is a wake hint; the caller always
    re-checks the queue, so missed notifications only cost latency."""
    def _wait():
        with pg_connect() as conn:
            conn.execute(f"LISTEN {channel}")
            for _ in conn.notifies(timeout=timeout_s, stop_after=1):
                return
    await asyncio.to_thread(_wait)
