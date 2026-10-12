# Cortex Code CLI + Agent SDK in SPCS: auth and runtime best practices

These are lessons from a production-style build: a multi-agent trade-break desk running on Snowpark Container Services (SPCS).
- **Versions:** `cortex-code-agent-sdk==1.0.7` and the Cortex Code CLI from the official install script (v1.1.x at build time).
- **What ran:** 5 long-running services and many job services, for days at a time.

Everything below was verified in SPCS unless marked **unverified**.

---

## 1. TL;DR

1. **Auth:** put `sessionTokenConfig: {mountConnectionConfig: true}` on every container that runs the CLI or SDK. Snowflake then writes a `connections.toml`, sets `SNOWFLAKE_HOME`, and keeps the token fresh.
   - No patches, copied tokens or key pairs are needed.
2. **Env vars alone do not work.** The CLI needs a connection file and fails with `No Snowflake connection available`.
3. **One credential for everything:** the SDK and the Python connector (`connection_name="default"`) both read the generated file.
4. **Reconnect on token expiry.** A Snowflake connector connection held for hours dies with `390114 Authentication token has expired`. Wrap cursors so they reconnect and retry once (see section 5).
5. **Identity = the service's owner role.** Give that role `SNOWFLAKE.CORTEX_USER`, warehouse usage, and only the data it should see.
   - Prompt instructions are not a security boundary; role grants are.
6. **Pin the SDK, install the CLI with the official script, build `linux/amd64`.**

---

## 2. Dockerfile (known-good)

```dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Cortex Code CLI (official installer). Puts `cortex` in /root/.local/bin.
RUN curl -LsS https://ai.snowflake.com/static/cc-scripts/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"
# Pin the SDK. Leave the connector unpinned: SDK 1.0.7 conflicts with a 3.x connector pin.
RUN pip install --no-cache-dir "cortex-code-agent-sdk==1.0.7" "snowflake-connector-python"
WORKDIR /app
COPY app/ ./
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "-u"]
CMD ["worker.py"]
```

**Build and push:**

```bash
REG=$(snow spcs image-registry url -c <conn>)
snow spcs image-registry login -c <conn>
docker build --platform linux/amd64 -t $REG/<db>/<schema>/<repo>/my-agent:1.0.0 .
docker push $REG/<db>/<schema>/<repo>/my-agent:1.0.0
```

**Notes:**
- `--platform linux/amd64` is mandatory on Apple Silicon; SPCS CPU pools are x86_64.
- The install script fetches the *current* CLI at build time. Record the version in your image (`RUN cortex --version`) and pin it once that matters; we did not pin it.
- Use immutable tags (`1.0.0`, `v6`), not `latest`. SPCS does not reliably re-pull a moved tag.
- Do not bake credentials or certificates into images. Mount them from Snowflake secrets.

---

## 3. Auth options we tested

| Option | Result |
|---|---|
| **A.** Your own `connections.toml` with `authenticator="oauth"`, `token_file_path="/snowflake/session/token"` | Works. Same identity as C. Fallback if you need a non-default profile. |
| **B.** Env vars only (`SNOWFLAKE_AUTHENTICATOR=OAUTH`, `SNOWFLAKE_TOKEN_FILE_PATH`) | **Fails.** The CLI requires a connection file. |
| **C.** `sessionTokenConfig.mountConnectionConfig: true` | **Works. Use this.** Snowflake owns the file, and its `token_file_path` points at the refreshed token. |
| **D.** Key pair via secret + `enableCustomCredentials` | Not tested; A and C were sufficient. |

**Token lifetime test:** in mode C, one SDK call every 10 minutes in the same container succeeded at t+10, 21, 31, 41, 52 and 62 minutes. That is past the 1-hour session-token lifetime, with no restarts.

**Service spec skeleton:**

```yaml
spec:
  containers:
  - name: worker
    image: /<db>/<schema>/<repo>/my-agent:1.0.0
    args: ["worker.py"]
    env:
      SNOWFLAKE_WAREHOUSE: MY_WH        # read by your code; also set QUERY_WAREHOUSE on the service
    sessionTokenConfig:
      mountConnectionConfig: true       # <- the whole auth story
    resources:
      requests: {cpu: "1", memory: 2Gi} # one CLI process per concurrent agent; ~1 CPU/2 GiB per 2 slots worked
      limits:   {cpu: "2", memory: 4Gi}
```

```sql
CREATE SERVICE MY_DB.APP.MY_AGENT
  IN COMPUTE POOL MY_POOL
  QUERY_WAREHOUSE = MY_WH
  MIN_INSTANCES = 1 MAX_INSTANCES = 1
  FROM SPECIFICATION $$ ...spec above... $$;
```

**Python connector from the same file:**

```python
import os, snowflake.connector
conn = snowflake.connector.connect(connection_name="default",
                                   warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE"))
```

**Node.js (`snowflake-sdk`)** has no `connections.toml` support. Read the token file directly, and re-read it on every new connection, because it rotates:

```js
snowflake.createConnection({
  account: process.env.SNOWFLAKE_ACCOUNT,             // injected by SPCS
  accessUrl: `https://${process.env.SNOWFLAKE_HOST}`, // injected by SPCS
  authenticator: 'OAUTH',
  token: fs.readFileSync('/snowflake/session/token', 'utf8').trim(),
  warehouse: process.env.SNOWFLAKE_WAREHOUSE,
});
```

---

## 4. Identity, roles and privileges

- **Who the agent runs as:** a service runs as a Snowflake-managed service user with the service owner's role as its primary role. `CURRENT_ROLE()` inside the agent is the owner role. Design that role as the agent's blast radius:
  - `GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <owner>`; without it model calls fail.
  - `USAGE` on the warehouse, database and schema; `SELECT` only on what the agent may read.
  - No write grants unless the agent must write.
  - Our agents had read-only reference data and *no* access to the ground-truth tables. That was enforced by grants, not by the prompt.
- **ACCOUNTADMIN cannot own services.** Create a dedicated owner role, grant it to ACCOUNTADMIN for operations, and run `CREATE SERVICE` as that role.
- **Split roles by trust level.** Agents that run model-generated SQL get the least-privileged role. Apps that need broader reads, such as dashboards, get a separate owner role.
- **Gotcha when testing grants from your laptop:** if your user has `DEFAULT_SECONDARY_ROLES = ('ALL')`, then `snow sql --role AGENT_ROLE` still inherits your other roles, so a "can the agent read X?" test lies.
  - Prefix test SQL with `USE SECONDARY ROLES NONE; USE WAREHOUSE <wh>;` to see exactly what the service sees.
- **Public endpoints:** add `serviceRoles` in the spec and `GRANT SERVICE ROLE <svc>!<role> TO ROLE <humans>`.
  - The ingress authenticates the user and passes `Sf-Context-Current-User`. Use that header for audit and attribution; reject requests without it.
- **Network:** the SDK and CLI talking to Cortex needed **no** external access integration in our services.
  - Add an EAI only for non-Snowflake egress, such as an external Postgres host, an MCP server URL or PyPI at runtime.
  - Our services ran with only a Postgres EAI attached. We saw no CLI update-check or telemetry failures, but we did not audit its outbound calls (**unverified**).

---

## 5. Long-running containers: token expiry

**What happened:** after about 7 hours, every agent call failed with `390114 (08001) Authentication token has expired`. A connector connection opened at startup kept its original session after the token file rotated. Breaks were claimed, failed and retried until escalated.

**Fix:** reconnect and retry once. The connector re-reads the rotated token file when it reconnects.

```python
import snowflake.connector
TOKEN_EXPIRED = {390111, 390112, 390114}

class SfConn:
    def __init__(self): self.conn = self._new()
    def _new(self): return snowflake.connector.connect(connection_name="default")
    def reconnect(self):
        try: self.conn.close()
        except Exception: pass
        self.conn = self._new()
    def cursor(self): return _RetryCursor(self)

class _RetryCursor:
    def __init__(self, owner): self._o, self._c = owner, owner.conn.cursor()
    def execute(self, *a, **k):
        try:
            return self._c.execute(*a, **k)
        except snowflake.connector.errors.DatabaseError as e:
            if getattr(e, "errno", None) not in TOKEN_EXPIRED: raise
            self._o.reconnect(); self._c = self._o.conn.cursor()
            return self._c.execute(*a, **k)
    def __getattr__(self, n): return getattr(self._c, n)
```

- The **SDK/CLI** path did not show this problem in our 62-minute test, because each CLI session reads the mounted config.
- We also recycle SDK clients every N turns (next section), which bounds session age. Long-lived CLI sessions over many hours were not separately tested (**unverified**). Recycling is cheap insurance.
- Do the same for Node: on errors matching `token|session|390114`, drop the connection and reconnect, re-reading the token file.

---

## 6. SDK usage patterns that worked

```python
from cortex_code_agent_sdk import (CortexCodeAgentOptions, CortexCodeSDKClient,
                                   AssistantMessage, ResultMessage, ToolUseBlock)

options = CortexCodeAgentOptions(
    cwd="/tmp",                       # writable scratch dir; keep the app dir read-only
    model="claude-opus-5-5",          # or whatever your account can call
    setting_sources=[],               # ignore user/project settings files: deterministic and faster startup
    effort="low",                     # fast tier; raise for reviewers
    max_turns=4,                      # bound tool loops
    system_prompt=SYSTEM_PROMPT,
    allowed_tools=["SQL"],            # least privilege for tools
    disallowed_tools=["Bash", "Write", "Edit", "Read", "Glob", "Grep"],
    output_format={"type": "json_schema", "schema": SCHEMA},  # structured, validated output
)

client = CortexCodeSDKClient(options)
await client.connect()
await client.query(prompt)
async with asyncio.timeout(90):                 # always bound a turn
    async for msg in client.receive_response():
        if isinstance(msg, ResultMessage):
            decision = msg.structured_output    # dict matching SCHEMA (check msg.is_error)
            usage = msg.usage                   # input/output/cache tokens for telemetry
```

**Practices:**
- **Treat the model as an advisor, not an authority.**
  - Use `output_format` with an `enum` for decisions, and validate the result against the schema yourself.
  - Compute amounts, tiers and routing in code or in the database from source data. Never take them from the model's payload.
- **Disable tools you don't need.** With SQL as the only tool, the owner role's grants are the agent's entire capability. A shell tool turns the container into the boundary.
- **Pre-fetch evidence in one query and put it in the prompt.** Tell the model to answer without tools unless a key is missing. This cut latency sharply (p50 about 3–7 s per decision).
- **Keep one persistent client per worker slot, recycled every ~8 turns.** That bounds context growth (per-turn input tokens) and session age. On any exception, close the client and create a fresh one next time.
- **Concurrency:** each `CortexCodeSDKClient` is a CLI process. 2 slots per container at 1–2 CPU / 2–4 GiB was comfortable. Scale out with service instances.
- **Hot-swap model and prompt without a redeploy.** Read `model` and `prompt_version` from a control table each loop. If either changed, close the client and rebuild the options.
- **MCP:** `mcp_servers` accepts dict configs (stdio, http or sse) only; there is no in-process MCP server. For custom tools, run a stdio MCP server process in the same container.
- **Telemetry:** record `num_turns`, tokens, LLM time versus tool time, and the tools used, per run. That makes model bake-offs and cost questions easy later.

---

## 7. Models and region

- **Check availability at deploy time** with `SELECT AI_COMPLETE('<model>', 'Reply with OK')` as the owner role.
- **If a model is missing in-region,** set `ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'` (ACCOUNTADMIN). This is an account-wide decision, so ask first.
- **Undocumented models can still work.** `gemini-3.8-flash` and `claude-haiku-4-5` worked through the SDK even though the SDK docs did not list them at the time. Verify by calling them; don't assume either way.
- **Our picks, from a 10-case evaluation:**
  - Fast investigator: `gemini-3.8-flash`, 10/10 correct, p50 3.4 s.
  - Independent reviewer: `claude-opus-5-5`, 4/4 planted traps caught, 0 false holds.

---

## 8. Operations checklist

- **Logs:** `SELECT SYSTEM$GET_SERVICE_LOGS('<db>.<schema>.<svc>', 0, '<container>', 1000)`. The line count must be **1000 or less**, otherwise it fails or returns nothing.
- **Status:** `SELECT SYSTEM$GET_SERVICE_STATUS('<svc>')`. Wait for `READY` and fail fast on `FAILED`.
- **Upgrade in place:** `ALTER SERVICE ... FROM SPECIFICATION $$...$$` with a new image tag. Public endpoint URLs survive; `CREATE OR REPLACE` changes them.
- **One-off work:** use `EXECUTE JOB SERVICE` for setup, evals and simulators.
  - It is synchronous unless you pass `ASYNC = TRUE`.
  - Read the logs before you `DROP SERVICE` the job.
- **Cost:** suspend services and pools between uses (`ALTER SERVICE ... SUSPEND`, `ALTER COMPUTE POOL ... SUSPEND`).
- **Secrets:** use `GENERIC_STRING` for certificates. Mounted with `directoryPath`, the value appears as the file `<dir>/secret_string`. `PASSWORD` secrets appear as `<dir>/username` and `<dir>/password`.
- **Quick probes before building agents:**
  - an auth probe that runs `SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE()` through the SDK's SQL tool
  - a model probe that sends one turn per candidate model
  - a token-survival probe that makes a call every 10 minutes for over 60 minutes

---

## 9. Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `No Snowflake connection available` | No connection file (env vars only) | Add `sessionTokenConfig.mountConnectionConfig: true` |
| `390114 Authentication token has expired` after hours | Long-held connector connection | Reconnect and retry wrapper (section 5) |
| Model call: not authorized / unknown model | Missing `CORTEX_USER`, or model not in region | Grant the database role; enable cross-region or pick another model |
| `exec format error` at container start | Image built for arm64 | `docker build --platform linux/amd64` |
| SDK hangs | No turn timeout, or a tool loop | `asyncio.timeout(...)` and `max_turns`; close and recreate the client on error |
| Agent can read data it shouldn't, in your laptop tests only | Your secondary roles leaking into the test | `USE SECONDARY ROLES NONE` in test SQL |
| `GET_SERVICE_LOGS` returns nothing | Line count over 1000 | Use 1000 or less |
| `pip` resolution conflict | Pinning `snowflake-connector-python` 3.x alongside SDK 1.0.7 | Leave the connector unpinned |
