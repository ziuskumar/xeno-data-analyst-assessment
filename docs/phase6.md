## 🎯 Phase Objective

The objective of Phase 6 was to convert the analytical findings from the previous phases into one clean, reproducible SQL query that returns Finance's expected:

**`target_base = 22`**

The final query correctly handles:

- 🏪 Merchant filtering
- 📢 Communication type filtering
- 📅 October 2026 date range
- ✅ Campaign eligibility
- 🔄 Multi-level retry chains
- 👤 Customer deduplication within retry families
- 📦 Repeated events in standalone campaigns
- 🧮 Final aggregation to `target_base`

---

# 6.1 — Final Query Requirements

The final SQL must:

1. Filter for `merchant_id = 501`.
2. Filter for `communication_type = '2'`.
3. Restrict communication logs to October 2026.
4. Include only eligible campaign creation statuses:
   - `approved`
   - `aborted`
   - `resumed`
   - `stopped`
5. Require `processing_status = 'processed'`.
6. Resolve complete campaign parent-child relationships.
7. Identify retry families.
8. Deduplicate customers within retry families.
9. Preserve every communication event in standalone campaigns.
10. Return Finance's expected `target_base = 22`.

---

# 6.2 — Recursive Campaign Tree

## 🎯 Purpose

Campaign retries can form chains longer than one level.

Example:

    9001
     └── 9002
          └── 9003

A simple self-join would only handle a fixed number of levels.

Therefore, a recursive CTE is used to map every campaign to its root campaign.

## SQL

    WITH RECURSIVE campaign_tree AS (

        SELECT
            id AS campaign_id,
            parent_id,
            id AS root_campaign_id
        FROM campaign
        WHERE parent_id IS NULL

        UNION ALL

        SELECT
            c.id AS campaign_id,
            c.parent_id,
            ct.root_campaign_id
        FROM campaign c
        JOIN campaign_tree ct
            ON c.parent_id = ct.campaign_id
    )

## Verified Campaign Tree

    campaign_id | parent_id | root_campaign_id
    ------------|-----------|-----------------
    9001        | NULL      | 9001
    9002        | 9001      | 9001
    9003        | 9002      | 9001
    9004        | 9001      | 9001
    9101        | NULL      | 9101
    9201        | NULL      | 9201
    9202        | 9201      | 9201

This correctly resolves:

    9001 → 9002 → 9003

as one retry family rooted at `9001`.

Campaign `9004` is structurally part of the `9001` family, but its communication records are later excluded because the campaign is not eligible for official reporting.

---

# 6.3 — Build the Eligible Communication Dataset

The communication logs are joined to the campaign hierarchy and filtered according to the assignment requirements.

## Required Scope

    merchant_id = 501
    communication_type = '2'
    October 2026

## Campaign Eligibility

    creation_status IN (
        'approved',
        'aborted',
        'resumed',
        'stopped'
    )

    processing_status = 'processed'

## SQL

    eligible_logs AS (

        SELECT
            cl.customer_id,
            ct.root_campaign_id
        FROM communication_log cl
        JOIN campaign_tree ct
            ON cl.communication_id = ct.campaign_id
        JOIN campaign c
            ON cl.communication_id = c.id

        WHERE cl.merchant_id = 501
          AND cl.communication_type = '2'
          AND cl.sent_time >= '2026-10-01'
          AND cl.sent_time < '2026-11-01'

          AND c.creation_status IN (
              'approved',
              'aborted',
              'resumed',
              'stopped'
          )

          AND c.processing_status = 'processed'
    )

## Result

    30 total communication-log rows
                    ↓
    26 eligible communication-log rows

Campaign `9004` contributes four communication-log records but is excluded because:

    9004
    creation_status = approval_awaiting

---

# 6.4 — Identify Underlying Communications

Repeated customer records were investigated to distinguish retry attempts from legitimate separate communication events.

## C2 — Retry

    9001 → failed
    9002 → delivered

Result:

    2 log rows → 1 underlying communication

---

## C3 — Multi-Level Retry

    9001 → failed
    9002 → failed
    9003 → delivered

Result:

    3 log rows → 1 underlying communication

This confirms that the solution must support multi-level retry chains.

---

## D1 — Retry

    9201 → failed
    9202 → delivered

Result:

    2 log rows → 1 underlying communication

---

## C20 — Legitimate Standalone Repetition

    9101 → delivered → October 10
    9101 → delivered → October 20

These are **not retries**.

Both events belong to a standalone campaign.

Therefore:

    2 log rows → 2 communication events

They must not be collapsed using:

    COUNT(DISTINCT customer_id)

---

# 6.5 — Classify Campaign Families

Campaign families are classified using the recursive campaign tree.

## SQL

    family_type AS (

        SELECT
            root_campaign_id,
            COUNT(*) AS campaigns_in_family,

            CASE
                WHEN COUNT(*) > 1
                    THEN 'RETRY_FAMILY'
                ELSE 'STANDALONE'
            END AS family_type

        FROM campaign_tree
        GROUP BY root_campaign_id
    )

## Verified Result

    root_campaign_id | campaigns | family_type
    -----------------|-----------|-------------
    9001             | 4         | RETRY_FAMILY
    9101             | 1         | STANDALONE
    9201             | 2         | RETRY_FAMILY

Therefore:

    9001 → RETRY_FAMILY
    9101 → STANDALONE
    9201 → RETRY_FAMILY

---

# 6.6 — Apply the Counting Rule

This is the core business logic of the assessment.

## 🔄 Retry Family

For retry-linked campaign families:

    COUNT(DISTINCT customer_id)

is used.

### Reason

Multiple communication attempts for the same customer represent one underlying communication.

Example:

    C3:
    9001 → failed
    9002 → failed
    9003 → delivered

becomes:

    1 underlying communication

---

## 📦 Standalone Campaign

For standalone campaigns:

    COUNT(*)

is used.

### Reason

Every communication-log row represents a separate communication event.

Example:

    C20:
    9101 → October 10
    9101 → October 20

becomes:

    2 communication events

not:

    1 customer

---

# 6.7 — Calculate Family-Level Counts

The counting rule is applied separately to each campaign family.

## SQL

    family_counts AS (

        SELECT
            el.root_campaign_id,

            CASE
                WHEN ft.family_type = 'RETRY_FAMILY'
                    THEN COUNT(DISTINCT el.customer_id)
                ELSE COUNT(*)
            END AS counted_communications

        FROM eligible_logs el

        JOIN family_type ft
            ON el.root_campaign_id = ft.root_campaign_id

        GROUP BY
            el.root_campaign_id,
            ft.family_type
    )

## Verified Family Counts

    root_campaign_id | family_type   | eligible logs | counted communications
    -----------------|---------------|---------------|-----------------------
    9001             | RETRY_FAMILY  | 13            | 10
    9101             | STANDALONE    | 7             | 7
    9201             | RETRY_FAMILY  | 6             | 5

Therefore:

    10 + 7 + 5 = 22

---

# 6.8 — Final Target Base

The family-level counts are summed to produce Finance's `target_base`.

## SQL

    SELECT
        SUM(counted_communications) AS target_base
    FROM family_counts;

## Verified Result

    target_base
    -----------
    22

---

# 6.9 — Final Submission Query

The complete final SQL query is:

    WITH RECURSIVE campaign_tree AS (

        SELECT
            id AS campaign_id,
            parent_id,
            id AS root_campaign_id
        FROM campaign
        WHERE parent_id IS NULL

        UNION ALL

        SELECT
            c.id AS campaign_id,
            c.parent_id,
            ct.root_campaign_id
        FROM campaign c
        JOIN campaign_tree ct
            ON c.parent_id = ct.campaign_id
    ),

    eligible_logs AS (

        SELECT
            cl.customer_id,
            ct.root_campaign_id
        FROM communication_log cl
        JOIN campaign_tree ct
            ON cl.communication_id = ct.campaign_id
        JOIN campaign c
            ON cl.communication_id = c.id

        WHERE cl.merchant_id = 501
          AND cl.communication_type = '2'
          AND cl.sent_time >= '2026-10-01'
          AND cl.sent_time < '2026-11-01'

          AND c.creation_status IN (
              'approved',
              'aborted',
              'resumed',
              'stopped'
          )

          AND c.processing_status = 'processed'
    ),

    family_type AS (

        SELECT
            root_campaign_id,
            COUNT(*) AS campaigns_in_family,

            CASE
                WHEN COUNT(*) > 1
                    THEN 'RETRY_FAMILY'
                ELSE 'STANDALONE'
            END AS family_type

        FROM campaign_tree
        GROUP BY root_campaign_id
    ),

    family_counts AS (

        SELECT
            el.root_campaign_id,

            CASE
                WHEN ft.family_type = 'RETRY_FAMILY'
                    THEN COUNT(DISTINCT el.customer_id)
                ELSE COUNT(*)
            END AS counted_communications

        FROM eligible_logs el

        JOIN family_type ft
            ON el.root_campaign_id = ft.root_campaign_id

        GROUP BY
            el.root_campaign_id,
            ft.family_type
    )

    SELECT
        SUM(counted_communications) AS target_base
    FROM family_counts;

---

# 6.10 — Final Reconciliation

The final SQL reconciles Finance's expected value:

    30 raw communication-log rows
            ↓
    30 rows in required scope
            ↓
    26 eligible rows
            ↓
    22 counted communications

Final:

    target_base = 22

---

# 🧮 Reconciliation Bridge

    30 raw communication-log rows
            ↓
    0 scope adjustment
            ↓
    30 scoped rows
            ↓
    -4 ineligible campaign rows
            ↓
    26 eligible rows
            ↓
    -3 retry-family reduction (9001)
            ↓
    23
            ↓
    +0 standalone adjustment (9101)
            ↓
    23
            ↓
    -1 retry-family reduction (9201)
            ↓
    22 target_base

---

# 🧠 Key Analytical Insight

The most important distinction in the solution is:

> **Retry-family records are deduplicated by customer because multiple attempts represent one underlying communication, while repeated events in a standalone campaign remain separate communications.**

This prevents incorrectly reducing the standalone campaign's repeated customer events.

A global:

    COUNT(DISTINCT customer_id)

would incorrectly produce `21` instead of `22`.

The correct approach applies different counting rules based on campaign family type.

---

# 🎤 Interview Defense

If asked:

## "How did you arrive at 22?"

Answer:

> I first restricted the communication logs to merchant 501, October 2026, and campaign communication type 2. I then joined the logs to campaigns and applied the required creation and processing status filters, which reduced 30 records to 26 eligible records. Next, I recursively resolved campaign parent-child relationships to identify retry families. For retry families, multiple attempts for the same customer represent one underlying communication, so I counted distinct customers. For standalone campaigns, every communication-log row remains a separate communication event. The resulting family counts were 10, 7, and 5, giving a final target_base of 22.

---

# ⚡ SQL Design Decisions

## Why Recursive CTE?

Retry chains can contain multiple levels:

    Original
       ↓
    Retry
       ↓
    Retry
       ↓
    Retry

A recursive CTE handles an arbitrary-depth hierarchy instead of assuming only one retry.

## Why COUNT(DISTINCT customer_id) for Retry Families?

Because multiple attempts for the same customer within a retry family represent one underlying communication.

## Why COUNT(*) for Standalone Campaigns?

Because repeated sends in a standalone campaign are independent communication events.

## Why Filter Eligibility After Building the Campaign Tree?

The hierarchy describes the structural campaign relationships, while eligibility determines which communication records count for reporting.

This allows an ineligible campaign such as `9004` to remain correctly connected to its parent family while contributing zero eligible records.

## Why Use a Half-Open Date Range?

The query uses:

    sent_time >= '2026-10-01'
    AND sent_time < '2026-11-01'

This includes every timestamp in October without depending on the exact time value on October 31.

---

# 🏆 Phase 6 Final Status

**PHASE 6 — FINAL SQL: 100% COMPLETE ✅**

The final SQL was executed successfully against `data/comm_log.db`.

Verified result:

    target_base = 22

Finance's expected target:

    target_base = 22

Result:

**✅ EXACT MATCH**

---

# 📌 Phase 6 Deliverables

| Deliverable | Status |
|---|---|
| Final SQL requirements | ✅ Complete |
| Recursive campaign tree | ✅ Complete |
| Eligible communication dataset | ✅ Complete |
| Retry-family identification | ✅ Complete |
| Standalone identification | ✅ Complete |
| Customer deduplication logic | ✅ Complete |
| Family-level counting | ✅ Complete |
| Final `target_base` query | ✅ Complete |
| SQL execution | ✅ Verified |
| Finance reconciliation | ✅ 22 |
| Phase 6 | 🟢 **100% COMPLETE** |

---

# 🚀 Next Phase

**Phase 7 — Validation + Edge Cases**

The purpose of Phase 7 is not to find the `22` again.

The purpose is to stress-test the logic and make sure the solution is robust and defensible before preparing the final GitHub submission.
"""
