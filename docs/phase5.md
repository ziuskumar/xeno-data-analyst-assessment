# PHASE 5 — RECONCILIATION BRIDGE

## Objective

Reconcile the raw `communication_log` count with Finance's expected `target_base = 22`.

### Scope

- Merchant: `501`
- Month: October 2026
- Communication Type: `2` — Campaign
- Finance Target: `22`

---

## 5.1 — Starting Naive Count

### SQL

    SELECT COUNT(*) AS naive_count
    FROM communication_log;

### Output

    naive_count
    -----------
    30

### Result

    Naive Count = 30

---

## 5.2 — Scope Adjustment

### SQL

    SELECT
        COUNT(*) AS scoped_count
    FROM communication_log
    WHERE merchant_id = 501
      AND communication_type = '2'
      AND sent_time >= '2026-10-01'
      AND sent_time < '2026-11-01';

### Output

    scoped_count
    ------------
    30

### Result

    30 Raw Rows
         ↓
    30 Scoped Rows

    Scope Adjustment = 0

---

## 5.3 — Campaign Eligibility Adjustment

A campaign is eligible only when:

    creation_status IN (
        'approved',
        'aborted',
        'resumed',
        'stopped'
    )

and:

    processing_status = 'processed'

### SQL

    SELECT
        COUNT(*) AS eligible_count
    FROM communication_log cl
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
      AND c.processing_status = 'processed';

### Output:

    eligible_count
    --------------
    26

### Result

Campaign `9004` is excluded because:

    creation_status = approval_awaiting

It has 4 communication-log rows.

    30 Scoped Rows
         ↓
    -4 Ineligible Rows
         ↓
    26 Eligible Rows

    Eligibility Adjustment = -4

---

## 5.4 — Identify Repeated Customers

### SQL

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
            cl.communication_id,
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
    SELECT
        customer_id,
        root_campaign_id,
        COUNT(*) AS log_rows
    FROM eligible_logs
    GROUP BY
        customer_id,
        root_campaign_id
    HAVING COUNT(*) > 1
    ORDER BY
        root_campaign_id,
        customer_id;

### Output

    customer_id | root_campaign_id | log_rows
    ------------|------------------|---------
    C2          | 9001             | 2
    C3          | 9001             | 3
    C20         | 9101             | 2
    D1          | 9201             | 2

### Finding

Repeated customers:

    C2
    C3
    C20
    D1

A repeated customer is not automatically a duplicate communication.

---

## 5.5 — Trace Campaign Parent Relationships

### SQL

    SELECT
        c.id AS campaign_id,
        c.name AS campaign_name,
        c.parent_id,
        p.name AS parent_campaign_name
    FROM campaign c
    LEFT JOIN campaign p
        ON c.parent_id = p.id
    ORDER BY c.id;

### Output

    9001 | Diwali Cart Recovery - Wave 1             | NULL | NULL
    9002 | Diwali Cart Recovery - Retry A            | 9001 | Diwali Cart Recovery - Wave 1
    9003 | Diwali Cart Recovery - Retry B            | 9002 | Diwali Cart Recovery - Retry A
    9004 | Diwali Cart Recovery - Retry C (pending) | 9001 | Diwali Cart Recovery - Wave 1
    9101 | Diwali Flash Sale - Standalone            | NULL | NULL
    9201 | Diwali Wave 2                             | NULL | NULL
    9202 | Diwali Wave 2 - Retry                     | 9201 | Diwali Wave 2

### Campaign Families

    Family A:
    9001 → 9002 → 9003
    9004 is also linked to 9001 but is ineligible.

    Standalone:
    9101

    Family B:
    9201 → 9202

---

## 5.6 — Build Recursive Campaign Tree

### SQL

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
    SELECT
        campaign_id,
        parent_id,
        root_campaign_id
    FROM campaign_tree
    ORDER BY campaign_id;

### Output

    campaign_id | parent_id | root_campaign_id
    ------------|-----------|----------------
    9001        | NULL      | 9001
    9002        | 9001      | 9001
    9003        | 9002      | 9001
    9004        | 9001      | 9001
    9101        | NULL      | 9101
    9201        | NULL      | 9201
    9202        | 9201      | 9201

### Finding

All retry levels are mapped to their root campaign.

    9001 → 9001
    9002 → 9001
    9003 → 9001
    9004 → 9001

    9101 → 9101

    9201 → 9201
    9202 → 9201

---

## 5.7 — Classify Campaign Families

### SQL

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
    family_type AS (
        SELECT
            root_campaign_id,
            COUNT(*) AS campaigns_in_family
        FROM campaign_tree
        GROUP BY root_campaign_id
    )
    SELECT
        root_campaign_id,
        campaigns_in_family,
        CASE
            WHEN campaigns_in_family > 1
                THEN 'RETRY_FAMILY'
            ELSE 'STANDALONE'
        END AS family_type
    FROM family_type
    ORDER BY root_campaign_id;

### Output

    root_campaign_id | campaigns_in_family | family_type
    -----------------|---------------------|-------------
    9001             | 4                   | RETRY_FAMILY
    9101             | 1                   | STANDALONE
    9201             | 2                   | RETRY_FAMILY

---

## 5.8 — Calculate Retry Family Adjustments

### SQL

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
            cl.id AS log_id,
            cl.customer_id,
            cl.communication_id,
            ct.root_campaign_id,
            cl.sent_time
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
            COUNT(*) AS campaigns_in_family
        FROM campaign_tree
        GROUP BY root_campaign_id
    )
    SELECT
        el.root_campaign_id,
        CASE
            WHEN ft.campaigns_in_family > 1
                THEN 'RETRY_FAMILY'
            ELSE 'STANDALONE'
        END AS family_type,
        COUNT(*) AS eligible_log_rows,
        CASE
            WHEN ft.campaigns_in_family > 1
                THEN COUNT(DISTINCT el.customer_id)
            ELSE COUNT(*)
        END AS counted_communications,
        COUNT(*) -
        CASE
            WHEN ft.campaigns_in_family > 1
                THEN COUNT(DISTINCT el.customer_id)
            ELSE COUNT(*)
        END AS adjustment
    FROM eligible_logs el
    JOIN family_type ft
        ON el.root_campaign_id = ft.root_campaign_id
    GROUP BY
        el.root_campaign_id,
        family_type
    ORDER BY
        el.root_campaign_id;

### Output

    root_campaign_id | family_type  | eligible_log_rows | counted_communications | adjustment
    -----------------|--------------|-------------------|------------------------|-----------
    9001             | RETRY_FAMILY | 13                | 10                     | 3
    9101             | STANDALONE   | 7                 | 7                      | 0
    9201             | RETRY_FAMILY | 6                 | 5                      | 1

### Adjustments

    Family 9001:
    13 attempts → 10 communications
    Adjustment = -3

    Standalone 9101:
    7 events → 7 communications
    Adjustment = 0

    Family 9201:
    6 attempts → 5 communications
    Adjustment = -1

    Total Retry Adjustment = -4

---

## 5.9 — Final Target Base Query

### SQL

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
            cl.id AS log_id,
            cl.customer_id,
            cl.communication_id,
            ct.root_campaign_id,
            cl.sent_time
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
            COUNT(*) AS campaigns_in_family
        FROM campaign_tree
        GROUP BY root_campaign_id
    ),
    family_counts AS (
        SELECT
            el.root_campaign_id,
            CASE
                WHEN ft.campaigns_in_family > 1
                    THEN COUNT(DISTINCT el.customer_id)
                ELSE COUNT(*)
            END AS counted_communications
        FROM eligible_logs el
        JOIN family_type ft
            ON el.root_campaign_id = ft.root_campaign_id
        GROUP BY
            el.root_campaign_id,
            ft.campaigns_in_family
    )
    SELECT
        SUM(counted_communications) AS final_target_base
    FROM family_counts;

### Output

    final_target_base
    -----------------
    22

---

# 🎯 Final Reconciliation Bridge

    30 Raw communication_log rows
             ↓
      Scope Adjustment: 0
             ↓
    30 Scoped Rows
             ↓
      Eligibility Adjustment: -4
             ↓
    26 Eligible Rows
             ↓
      Retry Family 9001: -3
             ↓
    23
             ↓
      Standalone Campaign 9101: 0
             ↓
    23
             ↓
      Retry Family 9201: -1
             ↓
    22 Target Base

---

# 📊 Final Reconciliation Table

| Step | Description | Adjustment | Running Total |
|---|---|---:|---:|
| 1 | Raw communication-log rows | — | 30 |
| 2 | Scope adjustment | 0 | 30 |
| 3 | Ineligible campaign `9004` | -4 | 26 |
| 4 | Retry Family `9001` | -3 | 23 |
| 5 | Standalone Campaign `9101` | 0 | 23 |
| 6 | Retry Family `9201` | -1 | **22** |

---

# 🧠 Key Analytical Rule

For retry-linked campaign families:

    COUNT(DISTINCT customer_id)

For standalone campaigns:

    COUNT(*)

The reason is that retry campaigns represent multiple attempts of the same underlying communication, while repeated sends inside a standalone campaign are legitimate separate communication events.

---

# 🔎 Important Examples

## C2

    9001 → failed
    9002 → delivered

    2 attempts → 1 communication
    Adjustment = -1

## C3

    9001 → failed
    9002 → failed
    9003 → delivered

    3 attempts → 1 communication
    Adjustment = -2

This demonstrates why recursive retry-family detection is required.

## D1

    9201 → failed
    9202 → delivered

    2 attempts → 1 communication
    Adjustment = -1

## C20

    9101 → delivered
    9101 → delivered

Because `9101` is standalone:

    2 events → 2 communications
    Adjustment = 0

---

# ⚠️ Important Insight

Do NOT simply use:

    COUNT(DISTINCT customer_id)

across the entire dataset.

That would incorrectly collapse C20's two legitimate standalone events.

The correct rule is:

    Retry Family
    → collapse repeated customer attempts

    Standalone Campaign
    → preserve every communication event

---

# ✅ Final Result

    Calculated target_base = 22
    Finance target_base    = 22

    STATUS: RECONCILED ✅

---

# 🏁 Phase 5 Completion

```text
PHASE 5 — RECONCILIATION BRIDGE

Starting Count              30
Scope Adjustment              0
Eligibility Adjustment       -4
Retry Family 9001            -3
Standalone 9101                0
Retry Family 9201            -1
--------------------------------
FINAL TARGET BASE            22

PHASE 5 STATUS: ✅ COMPLETE