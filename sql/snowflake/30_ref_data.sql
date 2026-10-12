-- Stage: reference data and break scenarios, generated in Snowflake.
-- Deterministic: every value derives from HASH(row number, salt), so reruns produce identical data.
-- Scenario evidence is internally consistent, so each break has one defensible expected action.

USE WAREHOUSE {{WH}};
USE SCHEMA {{DB}}.REF;

CREATE OR REPLACE TABLE COUNTERPARTIES AS
SELECT 'CP-' || LPAD(SEQ4() + 1, 3, '0') AS COUNTERPARTY_ID,
       ARRAY_CONSTRUCT('Aldgate Capital', 'Brookfield Securities', 'Cheapside Markets', 'Dorset Asset Mgmt',
                       'Eastcheap Partners', 'Fenchurch Prime', 'Gresham Trading', 'Holborn Investors',
                       'Ironmonger Fund', 'Jewry Street LP', 'Kingsway Securities', 'Lombard Clearing',
                       'Moorgate Capital', 'Newgate Markets', 'Old Broad Partners', 'Poultry Global',
                       'Queenhithe AM', 'Ropemaker Fund', 'Shoreditch Prime', 'Threadneedle Trading')[SEQ4()]::STRING AS NAME,
       'LEI' || LPAD(ABS(HASH(SEQ4(), 'lei')) % 1000000000, 17, '0') AS LEI,
       IFF(SEQ4() < 6, 'TIER1', 'TIER2') AS CREDIT_TIER
FROM TABLE(GENERATOR(ROWCOUNT => 20));

CREATE OR REPLACE TABLE SECURITIES (ISIN STRING, NAME STRING, ASSET_CLASS STRING, BASE_PRICE NUMBER(18,4)) AS
SELECT * FROM VALUES
  ('US0378331005', 'Apple Inc', 'EQUITY', 228.40), ('US5949181045', 'Microsoft Corp', 'EQUITY', 431.10),
  ('US02079K3059', 'Alphabet Inc A', 'EQUITY', 171.25), ('US0231351067', 'Amazon.com Inc', 'EQUITY', 186.90),
  ('US67066G1040', 'NVIDIA Corp', 'EQUITY', 121.75), ('US46625H1005', 'JPMorgan Chase', 'EQUITY', 211.30),
  ('US9128283W81', 'UST 2.75% 2028', 'GOVT', 97.84), ('US91282CJL54', 'UST 4.5% 2033', 'GOVT', 101.62),
  ('GB00BMGR2809', 'UK Gilt 4.25% 2034', 'GOVT', 99.37), ('DE0001102580', 'Bund 0% 2032', 'GOVT', 83.15);

-- Settlement instructions with history. Odd counterparties changed their USD SSI a week before the trade date.
CREATE OR REPLACE TABLE SSI AS
WITH cp AS (SELECT COUNTERPARTY_ID, ROW_NUMBER() OVER (ORDER BY COUNTERPARTY_ID) - 1 AS n FROM COUNTERPARTIES),
ccy AS (SELECT COLUMN1 AS CURRENCY FROM VALUES ('USD'), ('GBP'), ('EUR'))
SELECT cp.COUNTERPARTY_ID, ccy.CURRENCY,
       'BIC' || CHR(65 + ABS(HASH(cp.n, ccy.CURRENCY, 'b0')) % 26) || CHR(65 + ABS(HASH(cp.n, 'b1')) % 26) || 'US33' AS BIC,
       LPAD(ABS(HASH(cp.n, ccy.CURRENCY, 'acct0')) % 100000000, 10, '0') AS ACCOUNT_NO,
       '2024-01-01'::DATE AS EFFECTIVE_FROM,
       IFF(MOD(cp.n, 2) = 1 AND ccy.CURRENCY = 'USD', '{{SSI_CHANGE_DATE}}'::DATE, NULL) AS EFFECTIVE_TO,
       'ONBOARDING' AS SOURCE
FROM cp CROSS JOIN ccy
UNION ALL
SELECT cp.COUNTERPARTY_ID, 'USD',
       'BIC' || CHR(65 + ABS(HASH(cp.n, 'n0')) % 26) || CHR(65 + ABS(HASH(cp.n, 'n1')) % 26) || 'US66',
       LPAD(ABS(HASH(cp.n, 'acct1')) % 100000000, 10, '0'),
       '{{SSI_CHANGE_DATE}}'::DATE, NULL, 'SWIFT MT670 SSI UPDATE'
FROM cp WHERE MOD(cp.n, 2) = 1;

CREATE OR REPLACE TABLE FEE_SCHEDULE (CUSTODIAN STRING, FEE_TYPE STRING, AMOUNT NUMBER(18,2), CURRENCY STRING) AS
SELECT * FROM VALUES
  ('BNYM', 'SETTLEMENT_FEE', 18.50, 'USD'), ('STATE STREET', 'SETTLEMENT_FEE', 22.00, 'USD'),
  ('NORTHERN TRUST', 'SETTLEMENT_FEE', 20.00, 'USD'), ('CITI CUSTODY', 'SETTLEMENT_FEE', 25.00, 'USD'),
  ('BNYM', 'FX_SPREAD', 41.20, 'USD'), ('STATE STREET', 'FX_SPREAD', 39.80, 'USD');

-- Break scenario catalog. batch: EVAL (10 fixed for the investigator bake-off), QC (10 with 4 traps),
-- DEMO (500 for the live flood). Each row carries the facts the agents must discover from REF.
CREATE OR REPLACE TABLE BREAK_SCENARIOS AS
WITH spec AS (
  SELECT 'EVAL' AS BATCH, SEQ4() AS i, 10 AS n FROM TABLE(GENERATOR(ROWCOUNT => 10))
  UNION ALL SELECT 'QC', SEQ4(), 10 FROM TABLE(GENERATOR(ROWCOUNT => 10))
  UNION ALL SELECT 'DEMO', SEQ4(), 500 FROM TABLE(GENERATOR(ROWCOUNT => 500))
),
typed AS (
  SELECT s.*,
         CASE
           WHEN BATCH = 'EVAL' THEN ARRAY_CONSTRUCT('PRICE_SMALL', 'PRICE_VENDOR_CONFIRMS', 'PRICE_VENDOR_DISPUTES',
                'SSI_STALE', 'QTY_PARTIAL_ALLOC', 'CASH_FEE_SHORTFALL', 'AMBIGUOUS', 'SSI_STALE', 'PRICE_SMALL',
                'CASH_FEE_SHORTFALL')[i]::STRING
           WHEN BATCH = 'QC' THEN ARRAY_CONSTRUCT('CASH_FEE_SHORTFALL', 'TRAP_CASH_ALREADY_RECEIVED',
                'CASH_FEE_SHORTFALL', 'TRAP_CASH_WRONG_FEE', 'CASH_FEE_SHORTFALL', 'TRAP_CASH_ALREADY_RECEIVED',
                'CASH_FEE_SHORTFALL', 'TRAP_CASH_WRONG_FEE', 'CASH_FEE_SHORTFALL', 'CASH_FEE_SHORTFALL')[i]::STRING
           ELSE CASE
             WHEN ABS(HASH(i, 'mix')) % 100 < 30 THEN 'PRICE_SMALL'
             WHEN ABS(HASH(i, 'mix')) % 100 < 42 THEN 'PRICE_VENDOR_CONFIRMS'
             WHEN ABS(HASH(i, 'mix')) % 100 < 50 THEN 'PRICE_VENDOR_DISPUTES'
             WHEN ABS(HASH(i, 'mix')) % 100 < 65 THEN 'SSI_STALE'
             WHEN ABS(HASH(i, 'mix')) % 100 < 78 THEN 'QTY_PARTIAL_ALLOC'
             WHEN ABS(HASH(i, 'mix')) % 100 < 90 THEN 'CASH_FEE_SHORTFALL'
             WHEN ABS(HASH(i, 'mix')) % 100 < 94 THEN 'TRAP_CASH_ALREADY_RECEIVED'
             ELSE 'AMBIGUOUS' END
         END AS SCENARIO
  FROM spec s
),
base AS (
  SELECT t.*,
         t.BATCH || '-' || LPAD(t.i + 1, 4, '0') AS BREAK_ID,
         'TR-' || t.BATCH || '-' || LPAD(t.i + 1, 4, '0') AS TRADE_REF,
         ARRAY_CONSTRUCT('BNYM', 'STATE STREET', 'NORTHERN TRUST', 'CITI CUSTODY')[ABS(HASH(t.i, t.BATCH, 'cust')) % 4]::STRING AS CUSTODIAN,
         -- SSI scenarios need a counterparty whose USD SSI changed (odd index)
         'CP-' || LPAD(IFF(t.SCENARIO = 'SSI_STALE', 2 * (ABS(HASH(t.i, t.BATCH, 'cp')) % 10) + 2,
                           ABS(HASH(t.i, t.BATCH, 'cp')) % 20 + 1), 3, '0') AS COUNTERPARTY_ID,
         ABS(HASH(t.i, t.BATCH, 'sec')) % 10 AS SEC_IDX,
         ABS(HASH(t.i, t.BATCH, 'qty')) % 90 + 10 AS QTY_HUNDREDS
  FROM typed t
)
SELECT b.BREAK_ID, b.TRADE_REF, b.CUSTODIAN, b.COUNTERPARTY_ID, sec.ISIN, 'USD' AS CURRENCY,
       '{{SETTLE_DATE}}'::DATE AS SETTLE_DATE, b.BATCH, b.SCENARIO,
       b.QTY_HUNDREDS * 100 AS TRADE_QTY,
       sec.BASE_PRICE AS OUR_PRICE,
       CASE b.SCENARIO
         WHEN 'PRICE_SMALL' THEN ROUND(1 + ABS(HASH(b.i, b.BATCH, 'bps')) % 4, 1)
         WHEN 'PRICE_VENDOR_CONFIRMS' THEN 12 + ABS(HASH(b.i, b.BATCH, 'bps')) % 30
         WHEN 'PRICE_VENDOR_DISPUTES' THEN 15 + ABS(HASH(b.i, b.BATCH, 'bps')) % 40
         ELSE 0 END AS PRICE_DIFF_BPS,
       CASE b.SCENARIO WHEN 'QTY_PARTIAL_ALLOC' THEN -100 * (1 + ABS(HASH(b.i, b.BATCH, 'q')) % 5) ELSE 0 END AS QTY_DIFF,
       CASE
         WHEN b.SCENARIO IN ('CASH_FEE_SHORTFALL', 'TRAP_CASH_ALREADY_RECEIVED') THEN fee.AMOUNT
         WHEN b.SCENARIO = 'TRAP_CASH_WRONG_FEE' THEN fee.AMOUNT * 10
         ELSE 0 END AS CASH_DIFF,
       CASE
         WHEN b.SCENARIO IN ('CASH_FEE_SHORTFALL', 'TRAP_CASH_ALREADY_RECEIVED', 'TRAP_CASH_WRONG_FEE') THEN 8
         WHEN b.SCENARIO = 'SSI_STALE' THEN 7
         WHEN b.SCENARIO = 'AMBIGUOUS' THEN 6
         ELSE 3 + ABS(HASH(b.i, 'p')) % 3 END AS PRIORITY,
       CASE b.SCENARIO
         WHEN 'PRICE_SMALL' THEN 'Price break: custodian settled at a marginally different clean price than booked. Difference within normal rounding.'
         WHEN 'PRICE_VENDOR_CONFIRMS' THEN 'Price break: custodian applied an end-of-day price that differs from our booked execution price. Please confirm the correct price.'
         WHEN 'PRICE_VENDOR_DISPUTES' THEN 'Price break: custodian price does not match our booked price for this trade. Counterparty insists their price is correct.'
         WHEN 'SSI_STALE' THEN ARRAY_CONSTRUCT(
              'Settlement failed: receiving agent BIC on our instruction does not match the counterparty standing instruction; cash leg not delivered.',
              'DK - Don''t know: counterparty rejects delivery, account number on instruction is not theirs.',
              'Matching failure: place of settlement / agent differs from counterparty side instruction. Trade unmatched at CSD.')[ABS(HASH(b.i, 'msg')) % 3]::STRING
         WHEN 'QTY_PARTIAL_ALLOC' THEN 'Quantity break: custodian shows fewer shares delivered than our booked quantity for this trade.'
         WHEN 'CASH_FEE_SHORTFALL' THEN 'Cash break: net settlement amount received is short of expected by a small amount. Custodian notes standard charges applied.'
         WHEN 'TRAP_CASH_ALREADY_RECEIVED' THEN 'Cash break: net settlement amount short of expected. Custodian notes standard charges applied; please fund the shortfall.'
         WHEN 'TRAP_CASH_WRONG_FEE' THEN 'Cash break: settlement amount short of expected. Custodian states this is the standard settlement charge, please fund.'
         ELSE ARRAY_CONSTRUCT(
              'Please call re: this trade, something is not right with it, ops desk has questions.',
              'Counterparty says booking is wrong but has not said what is wrong. Awaiting more detail.',
              'Trade flagged by custodian compliance review. No further detail provided.')[ABS(HASH(b.i, 'amb')) % 3]::STRING
       END AS CUSTODIAN_MESSAGE,
       CASE b.SCENARIO
         WHEN 'PRICE_SMALL' THEN 'ACCEPT_PRICE_DIFF'
         WHEN 'PRICE_VENDOR_CONFIRMS' THEN 'ACCEPT_PRICE_DIFF'
         WHEN 'PRICE_VENDOR_DISPUTES' THEN 'ESCALATE'
         WHEN 'SSI_STALE' THEN 'REQUEST_SSI_UPDATE'
         WHEN 'QTY_PARTIAL_ALLOC' THEN 'BOOK_QTY_ADJUSTMENT'
         WHEN 'CASH_FEE_SHORTFALL' THEN 'CASH_MOVEMENT'
         ELSE 'ESCALATE' END AS EXPECTED_ACTION,
       b.SCENARIO LIKE 'TRAP_%' AS IS_QC_TRAP,
       b.SEC_IDX, b.i AS IDX
FROM base b
JOIN (SELECT ISIN, BASE_PRICE, ROW_NUMBER() OVER (ORDER BY ISIN) - 1 AS k FROM SECURITIES) sec ON sec.k = b.SEC_IDX
LEFT JOIN FEE_SCHEDULE fee ON fee.CUSTODIAN = b.CUSTODIAN AND fee.FEE_TYPE = 'SETTLEMENT_FEE';

-- Trades as booked. The booked cash is gross; fees explain fee-shortfall breaks.
CREATE OR REPLACE TABLE TRADES AS
SELECT TRADE_REF, COUNTERPARTY_ID, ISIN, 'BUY' AS SIDE, TRADE_QTY AS QTY, OUR_PRICE AS PRICE, CURRENCY,
       '{{TRADE_DATE}}'::DATE AS TRADE_DATE, SETTLE_DATE, CUSTODIAN,
       ROUND(TRADE_QTY * OUR_PRICE, 2) AS GROSS_CASH, 'BOOKED' AS STATUS
FROM BREAK_SCENARIOS;

-- Allocations: partial-allocation scenarios have one allocation cancelled, explaining the qty break.
CREATE OR REPLACE TABLE ALLOCATIONS AS
SELECT s.TRADE_REF, s.TRADE_REF || '-A1' AS ALLOC_ID, s.TRADE_QTY + s.QTY_DIFF AS QTY, 'ACTIVE' AS STATUS
FROM BREAK_SCENARIOS s
UNION ALL
SELECT s.TRADE_REF, s.TRADE_REF || '-A2', -s.QTY_DIFF, 'CANCELLED_BY_PM'
FROM BREAK_SCENARIOS s WHERE s.SCENARIO = 'QTY_PARTIAL_ALLOC';

-- Independent vendor prices: confirm the custodian price, or match ours (dispute).
CREATE OR REPLACE TABLE PRICES AS
SELECT s.ISIN, s.TRADE_REF, 'EOD_VENDOR' AS SOURCE, s.SETTLE_DATE - 1 AS PRICE_DATE,
       CASE s.SCENARIO
         WHEN 'PRICE_VENDOR_CONFIRMS' THEN ROUND(s.OUR_PRICE * (1 + s.PRICE_DIFF_BPS / 10000), 4)
         ELSE s.OUR_PRICE END AS PRICE
FROM BREAK_SCENARIOS s WHERE s.SCENARIO LIKE 'PRICE_%'
UNION ALL
SELECT s.ISIN, s.TRADE_REF, 'CUSTODIAN', s.SETTLE_DATE, ROUND(s.OUR_PRICE * (1 + s.PRICE_DIFF_BPS / 10000), 4)
FROM BREAK_SCENARIOS s WHERE s.SCENARIO LIKE 'PRICE_%';

-- Cash ledger. The "already received" trap has the shortfall already paid in by the custodian,
-- so funding it again would be a duplicate payment.
CREATE OR REPLACE TABLE CASH_LEDGER AS
SELECT s.TRADE_REF, 'SETTLEMENT' AS ENTRY_TYPE, -ROUND(s.TRADE_QTY * s.OUR_PRICE - s.CASH_DIFF, 2) AS AMOUNT,
       s.CURRENCY, '{{TRADE_DATE}} 09:00:00'::TIMESTAMP_NTZ AS BOOKED_AT, s.CUSTODIAN AS SOURCE
FROM BREAK_SCENARIOS s WHERE s.CASH_DIFF <> 0
UNION ALL
SELECT s.TRADE_REF, 'FEE_REBATE_RECEIVED', s.CASH_DIFF, s.CURRENCY, '{{TRADE_DATE}} 10:30:00'::TIMESTAMP_NTZ, s.CUSTODIAN
FROM BREAK_SCENARIOS s WHERE s.SCENARIO = 'TRAP_CASH_ALREADY_RECEIVED';

-- One-call evidence bundle for a break's trade: everything an investigator needs, as JSON.
CREATE OR REPLACE FUNCTION TRADE_EVIDENCE(P_TRADE_REF STRING)
RETURNS OBJECT
AS
$$
  SELECT OBJECT_CONSTRUCT(
    'trade', (SELECT OBJECT_CONSTRUCT(*) FROM {{DB}}.REF.TRADES t WHERE t.TRADE_REF = P_TRADE_REF),
    'counterparty', (SELECT OBJECT_CONSTRUCT(c.*) FROM {{DB}}.REF.COUNTERPARTIES c
                      JOIN {{DB}}.REF.TRADES t ON t.COUNTERPARTY_ID = c.COUNTERPARTY_ID
                     WHERE t.TRADE_REF = P_TRADE_REF),
    'ssi_history', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(s.*)) WITHIN GROUP (ORDER BY s.EFFECTIVE_FROM)
                      FROM {{DB}}.REF.SSI s JOIN {{DB}}.REF.TRADES t
                        ON t.COUNTERPARTY_ID = s.COUNTERPARTY_ID AND t.CURRENCY = s.CURRENCY
                     WHERE t.TRADE_REF = P_TRADE_REF),
    'allocations', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(a.*)) FROM {{DB}}.REF.ALLOCATIONS a
                     WHERE a.TRADE_REF = P_TRADE_REF),
    'prices', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(p.*)) FROM {{DB}}.REF.PRICES p WHERE p.TRADE_REF = P_TRADE_REF),
    'cash_ledger', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(l.*)) WITHIN GROUP (ORDER BY l.BOOKED_AT)
                      FROM {{DB}}.REF.CASH_LEDGER l WHERE l.TRADE_REF = P_TRADE_REF),
    'fee_schedule', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(f.*)) FROM {{DB}}.REF.FEE_SCHEDULE f
                      JOIN {{DB}}.REF.TRADES t ON t.CUSTODIAN = f.CUSTODIAN
                     WHERE t.TRADE_REF = P_TRADE_REF)
  )
$$;

CREATE OR REPLACE TABLE SIM_SETTLEMENT_LOG (
  IDEMPOTENCY_KEY STRING PRIMARY KEY, ACTION_ID NUMBER, BREAK_ID STRING, ACTION_TYPE STRING,
  PAYLOAD VARIANT, EXECUTED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Agent role (owns investigator and QC services): read reference data and call the evidence
-- function. Agents' SQL tool runs as this role, so it gets nothing writable and no ground truth.
GRANT SELECT ON TABLE COUNTERPARTIES TO ROLE {{AGENT_ROLE}};
GRANT SELECT ON TABLE SECURITIES TO ROLE {{AGENT_ROLE}};
GRANT SELECT ON TABLE SSI TO ROLE {{AGENT_ROLE}};
GRANT SELECT ON TABLE FEE_SCHEDULE TO ROLE {{AGENT_ROLE}};
GRANT SELECT ON TABLE TRADES TO ROLE {{AGENT_ROLE}};
GRANT SELECT ON TABLE ALLOCATIONS TO ROLE {{AGENT_ROLE}};
GRANT SELECT ON TABLE PRICES TO ROLE {{AGENT_ROLE}};
GRANT SELECT ON TABLE CASH_LEDGER TO ROLE {{AGENT_ROLE}};
GRANT SELECT ON TABLE COUNTERPARTIES TO ROLE {{SERVICE_ROLE}};
GRANT SELECT ON TABLE SECURITIES TO ROLE {{SERVICE_ROLE}};
GRANT SELECT ON TABLE SSI TO ROLE {{SERVICE_ROLE}};
GRANT SELECT ON TABLE FEE_SCHEDULE TO ROLE {{SERVICE_ROLE}};
GRANT SELECT ON TABLE TRADES TO ROLE {{SERVICE_ROLE}};
GRANT SELECT ON TABLE ALLOCATIONS TO ROLE {{SERVICE_ROLE}};
GRANT SELECT ON TABLE PRICES TO ROLE {{SERVICE_ROLE}};
GRANT SELECT ON TABLE CASH_LEDGER TO ROLE {{SERVICE_ROLE}};
GRANT USAGE ON FUNCTION TRADE_EVIDENCE(STRING) TO ROLE {{AGENT_ROLE}};

-- Service role (executor, console, simulator): writes the simulated settlement log and reads the
-- scenario catalog for the simulator.
GRANT SELECT ON TABLE BREAK_SCENARIOS TO ROLE {{SERVICE_ROLE}};
GRANT USAGE ON FUNCTION TRADE_EVIDENCE(STRING) TO ROLE {{SERVICE_ROLE}};
GRANT SELECT, INSERT ON TABLE SIM_SETTLEMENT_LOG TO ROLE {{SERVICE_ROLE}};

-- Node command center replays the DEMO catalog for its "Add breaks" button.
GRANT SELECT ON TABLE BREAK_SCENARIOS TO ROLE {{COMMAND_ROLE}};
