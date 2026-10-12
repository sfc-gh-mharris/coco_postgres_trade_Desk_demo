"""DESK_CONSOLE: human approval console (Streamlit on an SPCS public endpoint).

SPCS ingress authenticates every request; only roles granted the service role
DESK_CONSOLE!APPROVER (via DESK_APPROVER) reach this app. The approver identity comes from the
Sf-Context-Current-User header that SPCS injects, never from user input. Approvals are bound to
the payload hash the approver saw; Postgres rejects the approval if the action changed since.
"""
from __future__ import annotations

import json

import pandas as pd
import streamlit as st

from common import pg_connect

st.set_page_config(page_title="T+1 Break Desk", layout="wide")

user = st.context.headers.get("Sf-Context-Current-User")
if not user:
    st.error("No Snowflake identity on this request. Open the console through its SPCS endpoint.")
    st.stop()


@st.cache_resource
def conn():
    return pg_connect()


def q(sql: str, params=()):
    c = conn()
    try:
        return c.execute(sql, params).fetchall()
    except Exception:
        c.close()
        st.cache_resource.clear()
        return conn().execute(sql, params).fetchall()


st.title("T+1 Trade-Break Desk")
st.caption(f"Signed in as **{user}** through Snowflake. Every decision below is recorded under this identity.")

queue = {r["status"]: r["n"] for r in q("SELECT * FROM desk.v_queue")}
cols = st.columns(6)
for col, s in zip(cols, ["NEW", "CLAIMED", "PROPOSED", "RESOLVED", "ESCALATED", "REOPENED"]):
    col.metric(s.title(), queue.get(s, 0))

tab_pending, tab_agents, tab_events = st.tabs(["Pending approval", "Agent controls", "Event ledger"])

with tab_pending:
    rows = q("SELECT * FROM desk.v_pending_actions ORDER BY tier DESC, created_at")
    if not rows:
        st.info("Nothing waiting for a human.")
    for r in rows:
        tier_label = {0: "Tier 0 auto", 1: "Tier 1 human", 2: "Tier 2 QC + human"}[r["tier"]]
        with st.container(border=True):
            left, right = st.columns([3, 2])
            with left:
                st.markdown(f"**{r['break_id']}** - `{r['action_type']}` - {tier_label} - status `{r['status']}`")
                st.write(r["custodian_message"])
                st.markdown(f"*Investigator ({r['proposed_by_version']}):* {r['rationale']}")
                if r["qc_verdict"]:
                    st.markdown(f"*QC ({r['qc_model']}) {r['qc_verdict']}:* {r['qc_reason']}")
            with right:
                st.json(r["payload"], expanded=False)
                st.caption(f"payload sha256 {r['payload_sha256'][:16]}... expires {r['expires_at']:%H:%M} UTC")
                # A form submits the note together with the decision in one request.
                with st.form(key=f"f-{r['action_id']}", border=False):
                    note = st.text_input("Note")
                    a, b = st.columns(2)
                    can_approve = r["status"] == "PENDING_APPROVAL"
                    approve = a.form_submit_button("Approve", type="primary", disabled=not can_approve)
                    reject = b.form_submit_button("Reject")
                if approve or reject:
                    out = q("SELECT desk.approve_action(%s, %s, %s, %s, %s) AS o",
                            (r["action_id"], r["payload_sha256"], user, "APPROVE" if approve else "REJECT",
                             note or None))[0]["o"]
                    st.toast(f"{r['break_id']}: {out}")
                    st.rerun()

with tab_agents:
    st.write("Disabling a version stops new claims **and** blocks any of its approved actions that have "
             "not executed yet. The executor checks this at execution time.")
    for c in q("SELECT * FROM desk.agent_controls ORDER BY agent_role, agent_version"):
        a, b, d = st.columns([2, 3, 1])
        a.markdown(f"**{c['agent_version']}** ({c['agent_role']})")
        b.caption(f"{c['model']} - prompt {c['prompt_version']} - last change by {c['updated_by']}")
        label = "Kill" if c["enabled"] else "Enable"
        if d.button(label, key=f"ctl-{c['agent_version']}", type="primary" if c["enabled"] else "secondary"):
            q("SELECT desk.set_agent_control(%s, %s, %s) AS o", (c["agent_version"], not c["enabled"], user))
            st.rerun()

with tab_events:
    ev = q("SELECT * FROM desk.v_recent_events")
    df = pd.DataFrame(ev)
    if not df.empty:
        df["payload"] = df["payload"].map(lambda p: json.dumps(p)[:160])
    st.dataframe(df, use_container_width=True, hide_index=True)

if st.button("Refresh"):
    st.rerun()
