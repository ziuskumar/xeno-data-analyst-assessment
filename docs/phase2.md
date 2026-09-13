# 📊 Phase 2 — Naive Baseline

## 🎯 Objective

The objective of Phase 2 was to establish the **naive/obvious baseline count** before applying retry-chain logic or advanced business rules.

Finance provided the expected value:

> **`target_base = 22`**

Instead of jumping directly to 22,,I calculated the count progressively using the basic scope and eligibility rules. This creates a transparent starting point for the reconciliation bridge.

> ⚠️ **No raw data was deleted, modified, deduplicated, or cleaned during this phase.** The database was treated as read-only.

---

## 2.1️⃣ Raw Communication Count

### What I did

I first counted every record in the `communication_log` table without applying any filters.

### SQL

```sql
SELECT COUNT(*) AS naive_count
FROM communication_log;
```

### Result

```text
naive_count
-----------
30
```

### Finding

The database contains **30 raw communication-log records**.

This became the initial baseline for the investigation.

```text
Raw communication_log
        ↓
       30
```

---

## 2.2️⃣ Apply Assignment Scope

### What I did

I applied the assignment's basic reporting scope:

- `merchant_id = 501`
- October 2026
- `communication_type = '2'`

According to the data dictionary, `communication_type = '2'` represents a campaign communication.

### SQL

```sql
SELECT COUNT(*) AS scoped_count
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01'
  AND sent_time < '2026-11-01';
```

### Result

```text
scoped_count
------------
30
```

### Finding

The scope filters removed **zero records**.

All 30 communication-log records already belong to:

```text
Merchant:             501
Communication Type:   Campaign (2)
Date Range:           October 2026
```

Therefore:

```text
30 raw records
      ↓
30 scoped records
```

### Why this matters

This confirms that the mismatch with Finance's number is **not caused by merchant, date, or communication-type filtering**.

---

## 2.3️⃣ Apply Campaign Eligibility

### What I did

I joined the `communication_log` table with the `campaign` table using:

```text
communication_log.communication_id
                    ↓
              campaign.id
```

I then applied the official campaign eligibility rule.

A campaign is eligible when:

```text
creation_status IN (
    'approved',
    'aborted',
    'resumed',
    'stopped'
)
AND
processing_status = 'processed'
```

### SQL

```sql
SELECT COUNT(*) AS naive_eligible_count
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
```

### Result

```text
naive_eligible_count
--------------------
26
```

### Finding

The eligibility filter reduced the population:

```text
30 → 26
```

The **4 excluded records** belong to campaign `9004`:

```text
9004 — Diwali Cart Recovery - Retry C (pending)
```

Its status is:

```text
creation_status  = approval_awaiting
processing_status = processed
```

`approval_awaiting` is not part of the finalized creation-status set, so campaign `9004` is not eligible for official reporting.

Therefore:

```text
30 raw records
      ↓
4 records from ineligible campaign 9004 excluded
      ↓
26 eligible records
```

---

# 📈 Phase 2 Baseline

The complete progression is:

```text
Raw communication_log
        ↓
       30
        ↓
Assignment scope
        ↓
       30
        ↓
Campaign eligibility
        ↓
       26
```

Therefore:

> **Naive Eligible Count = 26**

---

# 🚨 Gap Identified

Finance's expected target:

```text
target_base = 22
```

Our naive eligible count:

```text
naive_eligible_count = 26
```

Therefore:

```text
26 - 22 = 4
```

There is a **4-record gap** that still needs to be explained.

### ⚠️ Important

I did **not** assume that these 4 records are duplicates.

The data dictionary indicates that:

- Retry attempts create new campaign rows.
- Retry chains can contain multiple levels.
- A customer can legitimately appear multiple times.
- Repeated sends in a standalone campaign can represent separate valid communication events.

Therefore, blindly applying:

```sql
DISTINCT customer_id
```

would be unsafe and could produce an incorrect business result.

---

# 🧠 Key Findings

| Investigation Step | Count | Change |
|---|---:|---:|
| Raw communication-log rows | **30** | — |
| Assignment scope applied | **30** | 0 |
| Campaign eligibility applied | **26** | -4 |
| Finance expected target | **22** | -4 remaining gap |

### Key conclusions

1. 📊 **30** communication-log records exist in the raw database.
2. 🏪 All 30 records belong to merchant `501`.
3. 📅 All 30 records fall within October 2026.
4. 📢 All 30 records have `communication_type = '2'`.
5. 🚫 Campaign `9004` is ineligible because its `creation_status` is `approval_awaiting`.
6. 📉 Campaign eligibility removes **4 records**.
7. 📊 The naive eligible population is **26 records**.
8. 🎯 Finance's expected `target_base` is **22**.
9. 🚨 The remaining unexplained gap is **4 records**.
10. 🔎 The remaining gap must be investigated using retry and communication business rules rather than generic duplicate removal.

---

# 🎯 Phase 2 Conclusion

Phase 2 established the **naive baseline of 26 eligible communication-log records**.

The reconciliation currently stands at:

```text
30 Raw Records
      ↓
30 In-Scope Records
      ↓
26 Eligible Records
      ↓
22 Finance Target
```

The remaining question is:

> **Why should 26 eligible communication-log records become a target base of 22?**

That question is intentionally left for the next phase.

---

# ✅ Phase 2 Status

```text
2.1 Raw Count Baseline       ✅ COMPLETE
2.2 Assignment Scope         ✅ COMPLETE
2.3 Campaign Eligibility     ✅ COMPLETE

Phase 2 → 100% COMPLETE
```

# 🔎 Next Phase — Phase 3: Investigate the Gap

The next phase will investigate the **26 → 22** difference by examining:

- 🔗 Retry relationships
- 👤 Repeated customers
- 🔄 Multi-level retry chains
- 📢 Standalone campaigns
- 📊 Communication attempts vs. underlying communications

The goal is to identify the exact business-rule adjustments required for the final reconciliation bridge.