# 🔍 Phase 3 — Investigating the Target-Base Gap

## Xeno Data Analyst Internship Assessment

---

## 🎯 Objective

After completing Phase 2, the baseline was:

```text
30 raw communication_log rows
        ↓
30 rows after scope filters
        ↓
26 eligible rows after campaign eligibility rules
        ↓
Finance target_base = 22
```

Therefore:

```text
26 - 22 = 4 unexplained rows
```

The objective of Phase 3 was to investigate **why the 26 eligible communication-log rows do not equal Finance's target base of 22**.

I did not modify, delete, or clean the raw database. The investigation was performed using analytical SQL against the original data.

---

# 🧭 Investigation Approach

I deliberately investigated the data step-by-step instead of assuming that repeated rows were duplicates.

```text
1. Identify customers appearing multiple times
              ↓
2. Inspect repeated customer events
              ↓
3. Trace campaign parent-child relationships
              ↓
4. Investigate multi-level retry chains
              ↓
5. Identify standalone campaigns
              ↓
6. Compare attempts vs underlying communications
              ↓
7. Determine the exact 4-row gap
```

### Core analytical principle

> A repeated customer is not automatically a duplicate.

A repeated customer can represent either:

- a retry belonging to the same underlying communication, or
- a legitimate separate communication event.

---

# 3.1 — Identify Repeated Customers

## Question

Which customers appear more than once in the eligible October 2026 dataset?

### Query

```sql
SELECT
    cl.customer_id,
    COUNT(*) AS log_count
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
  AND c.processing_status = 'processed'
GROUP BY cl.customer_id
HAVING COUNT(*) > 1
ORDER BY log_count DESC, cl.customer_id;
```

### Result

```text
C3   3 rows
C2   2 rows
C20  2 rows
D1   2 rows
```

### Observation

Only four customers appeared multiple times.

I did **not** immediately remove these rows because repeated rows had not yet been proven to be duplicates.

They were treated as investigation candidates.

---

# 3.2 — Inspect Repeated Customer Events

The next step was to inspect the actual campaign, parent relationship, delivery status, and timestamp for the repeated customers.

### Query

```sql
SELECT
    cl.customer_id,
    cl.communication_id,
    c.parent_id,
    c.name AS campaign_name,
    cl.delivery_status,
    cl.sent_time
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
  AND c.processing_status = 'processed'
  AND cl.customer_id IN ('C2', 'C3', 'C20', 'D1')
ORDER BY cl.customer_id, cl.sent_time;
```

---

## 🔴 C2 — Retry

Observed:

```text
C2 → 9001 → Failed
C2 → 9002 → Delivered
```

Campaign relationship:

```text
9002.parent_id = 9001
```

Therefore:

```text
2 log rows
      ↓
1 underlying communication
      ↓
Reduction = 1
```

### Conclusion

`9002` is a retry of `9001`.

These two rows should not be counted as two independent communications.

---

## 🔴 C3 — Multi-Level Retry

Observed:

```text
C3 → 9001 → Failed
C3 → 9002 → Failed
C3 → 9003 → Delivered
```

Campaign hierarchy:

```text
9001
  ↓
9002
  ↓
9003
```

Therefore:

```text
3 attempts
      ↓
1 underlying communication
      ↓
Reduction = 2
```

### Important finding

This is a **multi-level retry chain**.

The retry relationship is not limited to:

```text
Original → Retry
```

It can be:

```text
Original → Retry → Retry
```

Therefore, the final SQL needs to support recursive campaign relationships rather than assuming only one retry level.

---

## 🟢 C20 — Legitimate Repeated Standalone Send

Observed:

```text
C20 → 9101 → Delivered → 2026-10-10
C20 → 9101 → Delivered → 2026-10-20
```

### Initial mistake / hypothesis

At first, these rows looked like a possible duplicate because the same customer appeared twice.

However, I did **not** remove them based only on `customer_id`.

I investigated the campaign relationship.

Campaign `9101` was found to have:

```text
parent_id = NULL
child_count = 0
```

Therefore `9101` is a genuine **standalone campaign**.

The two C20 records represent two separate communication events:

```text
Oct 10 → Event 1
Oct 20 → Event 2
```

### Conclusion

```text
2 log rows
      ↓
2 legitimate communications
      ↓
Reduction = 0
```

### Important lesson

A simple:

```sql
COUNT(DISTINCT customer_id)
```

would incorrectly reduce C20's two legitimate events to one.

This is why generic deduplication is not sufficient for this business problem.

---

## 🔴 D1 — Retry

Observed:

```text
D1 → 9201 → Failed
D1 → 9202 → Delivered
```

Campaign relationship:

```text
9202.parent_id = 9201
```

Therefore:

```text
2 log rows
      ↓
1 underlying communication
      ↓
Reduction = 1
```

### Conclusion

`9202` is a retry of `9201`.

---

# 3.3 — Trace Campaign Parent-Child Relationships

To systematically understand retry relationships, I inspected the campaign hierarchy.

### Query

```sql
SELECT
    c.id AS campaign_id,
    c.name AS campaign_name,
    c.parent_id,
    p.name AS parent_campaign_name
FROM campaign c
LEFT JOIN campaign p
    ON c.parent_id = p.id
ORDER BY c.id;
```

### Result

```text
9001 | Diwali Cart Recovery - Wave 1            | NULL | NULL
9002 | Diwali Cart Recovery - Retry A           | 9001 | Diwali Cart Recovery - Wave 1
9003 | Diwali Cart Recovery - Retry B           | 9002 | Diwali Cart Recovery - Retry A
9004 | Diwali Cart Recovery - Retry C (pending) | 9001 | Diwali Cart Recovery - Wave 1
9101 | Diwali Flash Sale - Standalone           | NULL | NULL
9201 | Diwali Wave 2                            | NULL | NULL
9202 | Diwali Wave 2 - Retry                    | 9201 | Diwali Wave 2
```

### Campaign families identified

```text
Family A:

9001
  ↓
9002
  ↓
9003

9004
  ↑
also linked to 9001
```

```text
Family B:

9201
  ↓
9202
```

```text
Standalone:

9101
```

---

# 3.4 — Identify Root Campaigns

Because retry chains can have multiple levels, I used a recursive CTE to identify the root/original campaign for every campaign.

### Query

```sql
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
```

### Result

```text
campaign_id | parent_id | root_campaign_id
------------|-----------|----------------
9001        | NULL      | 9001
9002        | 9001      | 9001
9003        | 9002      | 9001
9004        | 9001      | 9001
9101        | NULL      | 9101
9201        | NULL      | 9201
9202        | 9201      | 9201
```

### Interpretation

The recursive hierarchy confirms:

```text
9001 → root 9001
9002 → root 9001
9003 → root 9001
9004 → root 9001

9101 → root 9101

9201 → root 9201
9202 → root 9201
```

This allows retry attempts from different campaign IDs to be associated with the same underlying campaign family.

---

# 3.5 — Verify Standalone Campaigns

I then explicitly checked which campaigns had neither a parent nor any child campaign.

### Query

```sql
SELECT
    c.id AS campaign_id,
    c.name AS campaign_name,
    c.parent_id,
    COUNT(child.id) AS child_count
FROM campaign c
LEFT JOIN campaign child
    ON child.parent_id = c.id
GROUP BY
    c.id,
    c.name,
    c.parent_id
ORDER BY c.id;
```

### Result

```text
9001 | Diwali Cart Recovery - Wave 1            | NULL | 2
9002 | Diwali Cart Recovery - Retry A           | 9001 | 1
9003 | Diwali Cart Recovery - Retry B           | 9002 | 0
9004 | Diwali Cart Recovery - Retry C (pending) | 9001 | 0
9101 | Diwali Flash Sale - Standalone           | NULL | 0
9201 | Diwali Wave 2                            | NULL | 1
9202 | Diwali Wave 2 - Retry                    | 9201 | 0
```

### Finding

Campaign `9101` satisfies:

```text
parent_id IS NULL
AND
child_count = 0
```

Therefore:

```text
9101 = Standalone campaign
```

This confirms why C20's two sends must remain separate.

---

# 3.6 — Compare Attempts vs Distinct Customers

To understand the scale of repeated records by campaign family, I compared total log rows with distinct customers.

### Query

```sql
SELECT
    root_campaign_id,
    COUNT(*) AS log_rows,
    COUNT(DISTINCT customer_id) AS distinct_customers,
    COUNT(*) - COUNT(DISTINCT customer_id) AS potential_reduction
FROM (
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
GROUP BY root_campaign_id
ORDER BY root_campaign_id;
```

### Result

```text
root_campaign_id | log_rows | distinct_customers | potential_reduction
-----------------|----------|--------------------|--------------------
9001             | 13       | 10                 | 3
9101             | 7        | 6                  | 1
9201             | 6        | 5                  | 1
```

---

# ⚠️ Important Mistake / False Lead

The diagnostic output initially suggested:

```text
9101:
7 log rows
6 distinct customers
difference = 1
```

A naive interpretation would be:

```text
7 - 6 = 1 duplicate
```

That would be **wrong**.

The extra row is C20's second legitimate standalone communication:

```text
C20 → Oct 10
C20 → Oct 20
```

Therefore:

```text
9101:
7 log rows → 7 valid communications
```

This investigation prevented an incorrect generic deduplication rule from being used.

---

# 🧠 Why COUNT(DISTINCT customer_id) Is Also Incorrect

A simple query such as:

```sql
SELECT COUNT(DISTINCT customer_id)
FROM communication_log;
```

would produce a customer count, not the required communication count.

For example:

```text
C20 → Oct 10
C20 → Oct 20
```

would become:

```text
COUNT(DISTINCT C20) = 1
```

But the business definition requires:

```text
C20 → Event 1
C20 → Event 2

Total = 2
```

Therefore the final solution must distinguish:

```text
Retry repetition
        vs
Legitimate standalone repetition
```

---

# 3.7 — Customer-Level Attempt Analysis

To validate the repeated-customer patterns at the campaign-family level, I grouped eligible logs by customer and root campaign.

### Query

```sql
SELECT
    customer_id,
    root_campaign_id,
    COUNT(*) AS log_rows
FROM (
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
GROUP BY
    customer_id,
    root_campaign_id
ORDER BY
    root_campaign_id,
    customer_id;
```

### Important results

```text
C2  | 9001 | 2
C3  | 9001 | 3

C20 | 9101 | 2

D1  | 9201 | 2
```

These four cases account for all repeated-customer behavior in the eligible dataset.

---

# 🎯 Phase 3 Final Reconciliation

The 4-row gap can now be explained completely.

```text
26 eligible communication-log rows
                ↓
        Retry reconciliation
                ↓
9001 family:
13 attempts → 10 underlying communications
Reduction = 3
                ↓
9201 family:
6 attempts → 5 underlying communications
Reduction = 1
                ↓
9101 standalone:
7 events → 7 communications
Reduction = 0
                ↓
10 + 7 + 5
                ↓
🎯 22
```

Therefore:

```text
26 - 3 - 1 = 22
```

---

# 📊 Final Phase 3 Evidence

| Campaign Family | Eligible Log Rows | Underlying Communications | Adjustment | Reason |
|---|---:|---:|---:|---|
| 9001 → 9002 → 9003 | 13 | 10 | -3 | Retry attempts |
| 9101 | 7 | 7 | 0 | Standalone; repeated sends are legitimate |
| 9201 → 9202 | 6 | 5 | -1 | Retry attempts |
| **Total** | **26** | **22** | **-4** | |

---

# 🔎 Customer-Level Explanation of the 4-Row Gap

```text
C2:
9001 Failed → 9002 Delivered
2 attempts → 1 communication
Reduction = 1

C3:
9001 Failed → 9002 Failed → 9003 Delivered
3 attempts → 1 communication
Reduction = 2

D1:
9201 Failed → 9202 Delivered
2 attempts → 1 communication
Reduction = 1

C20:
9101 Delivered → Oct 10
9101 Delivered → Oct 20
2 standalone events → 2 communications
Reduction = 0
```

Therefore:

```text
C2  → -1
C3  → -2
D1  → -1
C20 →  0
──────────
Total = -4
```

---

# 🧠 Key Analytical Learnings

### 1. Repeated rows are not automatically duplicates

A repeated customer must be investigated in the context of campaign relationships and business rules.

### 2. `parent_id` is critical

It allows retry campaigns to be connected to their original campaign.

### 3. Retry chains can be multi-level

The data contains:

```text
9001 → 9002 → 9003
```

Therefore a solution should not assume only one retry level.

### 4. Standalone campaigns behave differently

Campaign `9101` has no parent and no children.

Therefore repeated sends inside it are legitimate independent events.

### 5. Generic `COUNT(DISTINCT customer_id)` is insufficient

It would incorrectly collapse legitimate repeated standalone communications such as C20.

### 6. Raw data should not be modified

The task is an analytical reconciliation problem, not a database-cleaning task.

The correct approach is to preserve the source data and encode the business rules in SQL.

---

# ⚠️ Phase 3 Mistake / Course Correction

One of the main mistakes during the investigation was initially considering repeated customer rows as potential duplicates.

For example:

```text
C20 → 9101 → Oct 10
C20 → 9101 → Oct 20
```

could easily be treated as duplicate data.

Further investigation of `parent_id` and child relationships showed that `9101` is a standalone campaign, so both records are valid.

### Corrected reasoning

```text
Repeated customer
       ↓
Check campaign relationship
       ↓
Is it part of a retry chain?
       ├── YES → collapse retry attempts
       │
       └── NO → preserve as independent event
```

This correction was important because blindly deduplicating repeated customers would produce the wrong target base.

---

# ✅ Phase 3 Conclusion

The Finance target base of **22** is consistent with the underlying communication logic.

Starting from:

```text
26 eligible log rows
```

the investigation found:

```text
-3 rows from redundant retry attempts in the 9001 family
-1 row from a redundant retry attempt in the 9201 family
 0 rows removed from standalone campaign 9101
```

Therefore:

```text
26 - 3 - 1 = 22
```

### Final conclusion

> The 4-row difference is caused by retry attempts that belong to the same underlying communication. The 9001 retry family contributes a reduction of 3 rows, while the 9201 retry family contributes a reduction of 1 row. Campaign 9101 is a genuine standalone campaign, so its repeated C20 sends are legitimate separate events and must be preserved. The resulting target base is 22.

---

# 🚀 Next Phase

## Phase 4 — Retry / Campaign Logic

The next phase will convert the investigation findings into a reusable SQL logic that can:

```text
Identify eligible campaigns
        ↓
Build retry families
        ↓
Identify standalone campaigns
        ↓
Collapse retry attempts correctly
        ↓
Preserve legitimate standalone repeats
        ↓
Produce target_base = 22
```

The goal is to move from:

```text
"I manually explained why the answer is 22"
```

to:

```text
"My SQL reproduces 22 using the business rules."
```