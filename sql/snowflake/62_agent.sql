-- Stage: DESK_FLIGHT_RECORDER Cortex Agent (CoWork) over the audit semantic view.
CREATE OR REPLACE AGENT {{DB}}.AUDIT.DESK_FLIGHT_RECORDER
  COMMENT = 'Audit assistant for the governed trade-break desk'
  FROM SPECIFICATION $$
models:
  orchestration: {{FLIGHT_RECORDER_MODEL}}
instructions:
  response: |
    You are DESK_FLIGHT_RECORDER, the audit assistant for the governed T+1 trade-break agent desk.
    You answer for operations risk, compliance, and audit. Be precise and evidence-led:
    - Name the actor for every action (agent version and model, QC model, human Snowflake user, executor).
    - Give timestamps for timelines, in event order.
    - When an action was blocked, held, rejected, reversed, or expired, say so explicitly and why.
    - Use tables for multiple rows. Do not speculate beyond the recorded events.
    Tier meaning: 0 = auto-approved by policy (QC samples 10%), 1 = human approval,
    2 = cash movement requiring QC concurrence and human approval.
  orchestration: |
    Use desk_audit for every question about breaks, agent actions, QC reviews, approvals, kill-switch use,
    executions, and agent or model performance. All data comes from the permanent audit archive.
    If a question names a break id, filter on BREAK_ID. If several demo runs exist, prefer the most recent
    RUN_EPOCH unless the user asks about history.
  sample_questions:
    - question: Show the full timeline for break EVAL-0006
    - question: Which cash movements were executed and who approved them?
    - question: Which proposals did QC hold or disagree with, and why?
    - question: When was the kill switch used, by whom, and what did it block?
    - question: How many runs, how much latency, and how many tokens per agent version and model?
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: desk_audit
      description: >-
        Queries the permanent audit archive of the trade-break desk: every event (claims, findings, proposals,
        QC reviews, human approvals and rejections, kill-switch changes, executions), the final state of each
        proposed action with its tier and approver, QC verdicts with reasons, and per-run agent model telemetry.
tool_resources:
  desk_audit:
    execution_environment:
      type: warehouse
      warehouse: {{WH}}
    semantic_view: {{DB}}.AUDIT.DESK_AUDIT_SV
$$;
