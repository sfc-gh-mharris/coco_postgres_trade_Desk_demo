-- Stage: semantic view over the audit archive (exported from the reference build).
create or replace semantic view {{DB}}.AUDIT.DESK_AUDIT_SV
	tables (
		{{DB}}.AUDIT.DESK_EVENTS_ARCHIVE primary key (RUN_EPOCH,EVENT_ID) comment='Append-only ledger of every desk event, one row per event. Use for timelines, who-did-what, kill-switch history, and exceptions.',
		{{DB}}.AUDIT.ACTIONS_ARCHIVE primary key (RUN_EPOCH,ACTION_ID) comment='Latest state of each proposed action, per schema instance',
		{{DB}}.AUDIT.QC_REVIEWS_ARCHIVE primary key (ACTION_ID,REVIEW_ID,RUN_EPOCH) comment='Independent QC agent verdicts on proposed actions (CONCUR, HOLD, DISAGREE) with the reason.',
		{{DB}}.AUDIT.AGENT_RUNS_ARCHIVE primary key (RUN_EPOCH,RUN_ID) comment='One row per agent run (investigator or QC): model, latency, tokens, and outcome.'
	)
	relationships (
		DESK_EVENTS_ARCHIVE_TO_ACTIONS_ARCHIVE as DESK_EVENTS_ARCHIVE(RUN_EPOCH,ACTION_ID) references ACTIONS_ARCHIVE(RUN_EPOCH,ACTION_ID),
		QC_REVIEWS_ARCHIVE_TO_ACTIONS_ARCHIVE as QC_REVIEWS_ARCHIVE(RUN_EPOCH,ACTION_ID) references ACTIONS_ARCHIVE(RUN_EPOCH,ACTION_ID)
	)
	facts (
		AGENT_RUNS_ARCHIVE.TURNS as TURNS comment='Agent turns in the run.',
		AGENT_RUNS_ARCHIVE.INPUT_TOKENS as INPUT_TOKENS comment='Input tokens consumed, including cached reads.',
		AGENT_RUNS_ARCHIVE.OUTPUT_TOKENS as OUTPUT_TOKENS comment='Output tokens produced.',
		AGENT_RUNS_ARCHIVE.LLM_MS as LLM_MS comment='Model time in milliseconds.',
		AGENT_RUNS_ARCHIVE.TOOL_MS as TOOL_MS comment='Evidence lookup time in milliseconds (one TRADE_EVIDENCE query).'
	)
	dimensions (
		DESK_EVENTS_ARCHIVE.RUN_EPOCH as RUN_EPOCH comment='Identifier of one desk schema instance (demo run). Join on RUN_EPOCH plus the id.',
		DESK_EVENTS_ARCHIVE.EVENT_ID as EVENT_ID,
		DESK_EVENTS_ARCHIVE.BREAK_ID as BREAK_ID with synonyms=('break','trade break') comment='Trade break identifier, for example EVAL-0006 or DEMO-0042.',
		DESK_EVENTS_ARCHIVE.ACTION_ID as ACTION_ID,
		DESK_EVENTS_ARCHIVE.RUN_ID as RUN_ID,
		DESK_EVENTS_ARCHIVE.ACTOR_TYPE as ACTOR_TYPE comment='Who acted: agent (investigator), qc (QC reviewer), human (approver), executor, system, simulator.',
		DESK_EVENTS_ARCHIVE.ACTOR_ID as ACTOR_ID with synonyms=('who','user','approver') comment='Specific actor: agent worker slot, QC instance, the Snowflake user name of a human approver, or the executor instance.',
		DESK_EVENTS_ARCHIVE.EVENT_TYPE as EVENT_TYPE comment='Event kind. BREAK_RECEIVED, CLAIMED, RECLAIMED, FINDING, ACTION_PROPOSED, QC_CLAIMED, QC_REVIEWED, QC_REVERSAL, ACTION_APPROVED, ACTION_REJECTED, APPROVAL_HASH_MISMATCH, ACTION_EXPIRED, AGENT_DISABLED, AGENT_ENABLED, BLOCKED_BY_KILL_SWITCH, ACTION_EXECUTED, ESCALATED_MAX_ATTEMPTS.',
		DESK_EVENTS_ARCHIVE.AGENT_VERSION as AGENT_VERSION comment='Governed agent version (investigator-v1, investigator-v2, investigator-v3 canary, qc-v1).',
		DESK_EVENTS_ARCHIVE.MODEL as MODEL comment='LLM used for the event, when an agent produced it.',
		DESK_EVENTS_ARCHIVE.PAYLOAD as PAYLOAD comment='Event details as JSON (fence token, tier, verdict, note, receipt).',
		DESK_EVENTS_ARCHIVE.OCCURRED_AT as OCCURRED_AT comment='When the event happened.',
		ACTIONS_ARCHIVE.RUN_EPOCH as RUN_EPOCH,
		ACTIONS_ARCHIVE.ACTION_ID as ACTION_ID,
		ACTIONS_ARCHIVE.BREAK_ID as BREAK_ID,
		ACTIONS_ARCHIVE.ACTION_TYPE as ACTION_TYPE comment='Proposed action: ACCEPT_PRICE_DIFF, REQUEST_SSI_UPDATE, BOOK_QTY_ADJUSTMENT, CASH_MOVEMENT, ESCALATE.',
		ACTIONS_ARCHIVE.TIER as TIER comment='Risk tier set by policy, not by the model: 0 = auto-approved (QC samples 10%), 1 = human approval, 2 = cash movement needing QC concurrence and human approval.',
		ACTIONS_ARCHIVE.RULE_ID as RULE_ID comment='Policy rule that set the tier, for example R0-PRICE-TOL or R2-CASH.',
		ACTIONS_ARCHIVE.STATUS as STATUS comment='Action lifecycle: PENDING_QC, QC_HOLD, PENDING_APPROVAL, APPROVED, AUTO_APPROVED, REJECTED, EXECUTED, BLOCKED (kill switch), EXPIRED.',
		ACTIONS_ARCHIVE.QC_STATUS as QC_STATUS comment='QC state: NOT_REQUIRED, PENDING, SAMPLE_PENDING, CONCUR, HOLD, DISAGREE.',
		ACTIONS_ARCHIVE.PROPOSED_BY_VERSION as PROPOSED_BY_VERSION comment='Investigator agent version that proposed the action.',
		ACTIONS_ARCHIVE.PAYLOAD_SHA256 as PAYLOAD_SHA256 comment='Hash of the action payload the approver saw; approvals are bound to it.',
		ACTIONS_ARCHIVE.RATIONALE as RATIONALE comment='Investigator''s reasoning for the proposal.',
		ACTIONS_ARCHIVE.APPROVED_BY as APPROVED_BY with synonyms=('approver','who approved') comment='Snowflake user who approved or rejected, or policy:<rule> for tier-0 auto-approval.',
		ACTIONS_ARCHIVE.APPROVED_AT as APPROVED_AT,
		ACTIONS_ARCHIVE.EXECUTED_AT as EXECUTED_AT comment='When the executor carried out the action; null if not executed.',
		ACTIONS_ARCHIVE.CREATED_AT as CREATED_AT,
		QC_REVIEWS_ARCHIVE.RUN_EPOCH as RUN_EPOCH,
		QC_REVIEWS_ARCHIVE.REVIEW_ID as REVIEW_ID,
		QC_REVIEWS_ARCHIVE.ACTION_ID as ACTION_ID,
		QC_REVIEWS_ARCHIVE.REVIEWER_VERSION as REVIEWER_VERSION,
		QC_REVIEWS_ARCHIVE.MODEL as MODEL comment='LLM used by the QC reviewer.',
		QC_REVIEWS_ARCHIVE.REVIEW_KIND as REVIEW_KIND comment='PRE_APPROVAL for tier-2 actions, POST_SAMPLE for sampled tier-0 auto-approvals.',
		QC_REVIEWS_ARCHIVE.VERDICT as VERDICT comment='QC verdict: CONCUR, HOLD (blocked before approval), DISAGREE (auto-resolution reversed).',
		QC_REVIEWS_ARCHIVE.REASON as REASON comment='QC''s evidence-based explanation.',
		QC_REVIEWS_ARCHIVE.CREATED_AT as CREATED_AT,
		AGENT_RUNS_ARCHIVE.RUN_EPOCH as RUN_EPOCH,
		AGENT_RUNS_ARCHIVE.RUN_ID as RUN_ID,
		AGENT_RUNS_ARCHIVE.BREAK_ID as BREAK_ID,
		AGENT_RUNS_ARCHIVE.WORKER_ID as WORKER_ID comment='Service instance and slot that ran the agent.',
		AGENT_RUNS_ARCHIVE.AGENT_VERSION as AGENT_VERSION,
		AGENT_RUNS_ARCHIVE.AGENT_ROLE as AGENT_ROLE comment='investigator or qc.',
		AGENT_RUNS_ARCHIVE.MODEL as MODEL,
		AGENT_RUNS_ARCHIVE.OUTCOME as OUTCOME comment='Run result, for example PROPOSED:CASH_MOVEMENT:PENDING_QC, NO_DECISION, READY_FOR_APPROVAL, HELD.',
		AGENT_RUNS_ARCHIVE.STARTED_AT as STARTED_AT,
		AGENT_RUNS_ARCHIVE.ENDED_AT as ENDED_AT
	)
	metrics (
		DESK_EVENTS_ARCHIVE.EVENT_COUNT as COUNT(EVENT_ID) comment='Number of events.',
		ACTIONS_ARCHIVE.ACTION_COUNT as COUNT(ACTION_ID) comment='Number of proposed actions.',
		ACTIONS_ARCHIVE.EXECUTED_COUNT as COUNT(EXECUTED_AT) comment='Number of executed actions.',
		AGENT_RUNS_ARCHIVE.RUN_COUNT as COUNT(RUN_ID) comment='Number of agent runs.',
		AGENT_RUNS_ARCHIVE.AVG_LLM_SECONDS as AVG(LLM_MS) / 1000 comment='Average model time per run, seconds.',
		AGENT_RUNS_ARCHIVE.TOTAL_INPUT_TOKENS as SUM(INPUT_TOKENS) comment='Total input tokens.',
		AGENT_RUNS_ARCHIVE.TOTAL_OUTPUT_TOKENS as SUM(OUTPUT_TOKENS) comment='Total output tokens.'
	)
	comment='Flight recorder for the governed T+1 trade-break agent desk. Permanent archive of every event (agent claims, findings, proposals, QC reviews, human approvals, kill-switch use, executions), the final state of each proposed action, QC verdicts, and per-run model telemetry. RUN_EPOCH identifies one desk schema instance; join tables on RUN_EPOCH plus the id.'
	ai_verified_queries (
		BREAK_TIMELINE AS ( 
QUESTION 'What is the complete timeline of events for trade break EVAL-0006?' 
VERIFIED_AT 1791486758
VERIFIED_BY '{{INSTALL_USER}}'
ONBOARDING_QUESTION false
SQL 'SELECT e.OCCURRED_AT, e.ACTOR_TYPE, e.ACTOR_ID, e.EVENT_TYPE, e.AGENT_VERSION, e.MODEL FROM desk_events_archive AS e WHERE e.BREAK_ID = ''EVAL-0006'' ORDER BY e.OCCURRED_AT, e.EVENT_ID'),
		EXECUTED_CASH_MOVEMENTS AS ( 
QUESTION 'Which cash movements were executed and who approved them?' 
VERIFIED_AT 1791486758
VERIFIED_BY '{{INSTALL_USER}}'
ONBOARDING_QUESTION false
SQL 'SELECT a.BREAK_ID, a.ACTION_TYPE, a.TIER, a.APPROVED_BY, a.APPROVED_AT, a.EXECUTED_AT FROM actions_archive AS a WHERE NOT a.EXECUTED_AT IS NULL AND a.ACTION_TYPE = ''CASH_MOVEMENT'' ORDER BY a.EXECUTED_AT'),
		QC_HOLDS_AND_DISAGREEMENTS AS ( 
QUESTION 'Which proposals did QC hold or disagree with, and why?' 
VERIFIED_AT 1791486758
VERIFIED_BY '{{INSTALL_USER}}'
ONBOARDING_QUESTION false
SQL 'SELECT a.BREAK_ID, a.ACTION_TYPE, a.PROPOSED_BY_VERSION, r.VERDICT, r.MODEL, r.REASON FROM qc_reviews_archive AS r JOIN actions_archive AS a ON a.RUN_EPOCH = r.RUN_EPOCH AND a.ACTION_ID = r.ACTION_ID WHERE r.VERDICT IN (''HOLD'', ''DISAGREE'') ORDER BY r.CREATED_AT'),
		KILL_SWITCH_HISTORY AS ( 
QUESTION 'When was the kill switch used, by whom, and what did it block?' 
VERIFIED_AT 1791486758
VERIFIED_BY '{{INSTALL_USER}}'
ONBOARDING_QUESTION false
SQL 'SELECT e.OCCURRED_AT, e.ACTOR_ID, e.EVENT_TYPE, e.AGENT_VERSION, e.BREAK_ID FROM desk_events_archive AS e WHERE e.EVENT_TYPE IN (''AGENT_DISABLED'', ''AGENT_ENABLED'', ''BLOCKED_BY_KILL_SWITCH'') ORDER BY e.OCCURRED_AT'),
		AGENT_MODEL_TELEMETRY AS ( 
QUESTION 'How many runs, how much latency, and how many tokens per agent version and model?' 
VERIFIED_AT 1791486758
VERIFIED_BY '{{INSTALL_USER}}'
ONBOARDING_QUESTION false
SQL 'SELECT r.AGENT_VERSION, r.MODEL, COUNT(*) AS RUNS, AVG(r.LLM_MS) AS AVG_LLM_MS, SUM(r.INPUT_TOKENS) AS INPUT_TOKENS, SUM(r.OUTPUT_TOKENS) AS OUTPUT_TOKENS FROM agent_runs_archive AS r GROUP BY r.AGENT_VERSION, r.MODEL ORDER BY RUNS DESC'),
		ACTIONS_BY_TIER_STATUS AS ( 
QUESTION 'How many actions are in each tier and status?' 
VERIFIED_AT 1791486758
VERIFIED_BY '{{INSTALL_USER}}'
ONBOARDING_QUESTION false
SQL 'SELECT a.TIER, a.STATUS, COUNT(*) AS ACTIONS FROM actions_archive AS a GROUP BY a.TIER, a.STATUS ORDER BY a.TIER, a.STATUS')
	)
	with extension (CA='{"tables":[{"name":"DESK_EVENTS_ARCHIVE","dimensions":[{"name":"RUN_EPOCH"},{"name":"EVENT_ID"},{"name":"BREAK_ID"},{"name":"ACTION_ID"},{"name":"RUN_ID"},{"name":"ACTOR_TYPE"},{"name":"ACTOR_ID"},{"name":"EVENT_TYPE"},{"name":"AGENT_VERSION"},{"name":"MODEL"},{"name":"PAYLOAD"}],"metrics":[{"name":"EVENT_COUNT"}],"time_dimensions":[{"name":"OCCURRED_AT"}]},{"name":"ACTIONS_ARCHIVE","dimensions":[{"name":"RUN_EPOCH"},{"name":"ACTION_ID"},{"name":"BREAK_ID"},{"name":"ACTION_TYPE"},{"name":"TIER"},{"name":"RULE_ID"},{"name":"STATUS"},{"name":"QC_STATUS"},{"name":"PROPOSED_BY_VERSION"},{"name":"PAYLOAD_SHA256"},{"name":"RATIONALE"},{"name":"APPROVED_BY"}],"metrics":[{"name":"ACTION_COUNT"},{"name":"EXECUTED_COUNT"}],"time_dimensions":[{"name":"APPROVED_AT"},{"name":"EXECUTED_AT"},{"name":"CREATED_AT"}]},{"name":"QC_REVIEWS_ARCHIVE","dimensions":[{"name":"RUN_EPOCH"},{"name":"REVIEW_ID"},{"name":"ACTION_ID"},{"name":"REVIEWER_VERSION"},{"name":"MODEL"},{"name":"REVIEW_KIND"},{"name":"VERDICT"},{"name":"REASON"}],"time_dimensions":[{"name":"CREATED_AT"}]},{"name":"AGENT_RUNS_ARCHIVE","dimensions":[{"name":"RUN_EPOCH"},{"name":"RUN_ID"},{"name":"BREAK_ID"},{"name":"WORKER_ID"},{"name":"AGENT_VERSION"},{"name":"AGENT_ROLE"},{"name":"MODEL"},{"name":"OUTCOME"}],"facts":[{"name":"TURNS"},{"name":"INPUT_TOKENS"},{"name":"OUTPUT_TOKENS"},{"name":"LLM_MS"},{"name":"TOOL_MS"}],"metrics":[{"name":"RUN_COUNT"},{"name":"AVG_LLM_SECONDS"},{"name":"TOTAL_INPUT_TOKENS"},{"name":"TOTAL_OUTPUT_TOKENS"}],"time_dimensions":[{"name":"STARTED_AT"},{"name":"ENDED_AT"}]}],"relationships":[{"name":"QC_REVIEWS_ARCHIVE_TO_ACTIONS_ARCHIVE","relationship_type":"many_to_one","join_type":"inner"},{"name":"DESK_EVENTS_ARCHIVE_TO_ACTIONS_ARCHIVE","relationship_type":"many_to_one","join_type":"left_outer"}]}');
