
# VALIDATION + EDGE CASES

---

## 🎯Phase 7 Objective

The objective of Phase 7 is to validate the final SQL and confirm that the business logic is correct beyond simply producing the expected value of:

    target_base = 22

Phase 7 focuses on:

- 🔢 Reconciliation validation
- 📊 Family-level validation
- 🔄 Retry-chain validation
- 👤 Customer deduplication validation
- 🚫 Eligibility validation
- 📦 Standalone campaign validation
- 🧬 Multi-level retry validation
- 🧮 Adjustment validation
- 🧪 Edge-case stress testing
- ⚡ Final SQL integrity

The goal is to ensure that the result is **correct, explainable, and defensible in an interview**.

---

# 7.1 — Reconciliation Validation

## 🎯 Objective

Verify the complete journey from the raw communication-log count to Finance's final target.

## Reconciliation

    30 raw communication-log rows
            ↓
    30 scoped rows
            ↓
    26 eligible rows
            ↓
    22 target_base

## Validation Result

    Raw rows       = 30
    Scoped rows    = 30
    Eligible rows = 26
    Target base    = 22

### ✅ Result

The final SQL reconciles correctly to Finance's expected:

    target_base = 22

---

# 7.2 — Family-Level Validation

The eligible records were validated independently by campaign family.

## Verified Results

    Root Campaign | Family Type   | Eligible Logs | Counted
    --------------|---------------|---------------|--------
    9001          | RETRY_FAMILY  | 13            | 10
    9101          | STANDALONE    | 7             | 7
    9201          | RETRY_FAMILY  | 6             | 5

## Final Calculation

    10 + 7 + 5 = 22

### ✅ Result

Every eligible campaign family contributes the expected number of underlying communications.

---

# 7.3 — Retry-Chain Validation

## 🎯 Objective

Confirm that retry chains are resolved recursively rather than assuming only one retry level.

## Dataset Example

    9001
      ↓
    9002
      ↓
    9003

The recursive campaign tree maps:

    9001 → root 9001
    9002 → root 9001
    9003 → root 9001

Therefore, all three campaigns belong to the same retry family.

### ✅ Result

The recursive CTE correctly handles multi-level retry relationships.

---

# 7.4 — Customer Deduplication Validation

Repeated customers were checked to determine whether they represent retries or separate events.

## Retry Family Cases

### C2

    9001 → failed
    9002 → delivered

    2 rows → 1 communication

### C3

    9001 → failed
    9002 → failed
    9003 → delivered

    3 rows → 1 communication

### D1

    9201 → failed
    9202 → delivered

    2 rows → 1 communication

## Standalone Case

### C20

    9101 → delivered
    9101 → delivered

These are separate events because both records belong to the same standalone campaign.

    2 rows → 2 communications

### ✅ Result

Customer deduplication is applied only where the business rule requires it.

---

# 7.5 — Eligibility Validation

Campaign `9004` was specifically validated.

## Campaign

    campaign_id = 9004
    parent_id = 9001
    creation_status = approval_awaiting
    processing_status = processed

Although `9004` contains communication-log records, its creation status is not in the eligible set.

Therefore, its records are excluded.

## Effect

    30 total communication-log rows
            ↓
    -4 records from ineligible campaign 9004
            ↓
    26 eligible rows

### ✅ Result

`9004` contributes:

    0

to the official `target_base`.

---

# 7.6 — Standalone Campaign Validation

The standalone campaign is:

    9101

It has no parent and no child campaigns.

Therefore:

    9101 → STANDALONE

It contains seven eligible communication-log rows.

    7 logs → 7 communications

## Important Case: C20

C20 appears twice:

    C20 → 9101 → October 10
    C20 → 9101 → October 20

These are two legitimate communication events.

Therefore:

    COUNT(*) = 2

must be used for the standalone campaign.

Using:

    COUNT(DISTINCT customer_id)

would incorrectly produce:

    1

and reduce the final answer from:

    22

to:

    21

### ✅ Result

Standalone repeated communication events are preserved correctly.

---

# 7.7 — Multi-Level Retry Customer Validation

Customer C3 provides the most important multi-level retry test.

## Communication History

    C3
      ↓
    9001 → failed
      ↓
    9002 → failed
      ↓
    9003 → delivered

There are:

    3 communication-log rows

But they represent:

    1 underlying communication

Therefore:

    3 rows → 1 communication

### ✅ Result

The recursive family logic combined with customer deduplication correctly handles multi-level retries.

---

# 7.8 — Adjustment Validation

The eligible count is:

    26

The reductions caused by retry deduplication are:

## Family 9001

    13 eligible logs
    10 counted communications

Adjustment:

    13 - 10 = 3

    Adjustment = -3

---

## Family 9101

    7 eligible logs
    7 counted communications

Adjustment:

    7 - 7 = 0

    Adjustment = 0

---

## Family 9201

    6 eligible logs
    5 counted communications

Adjustment:

    6 - 5 = 1

    Adjustment = -1

---

## Total Adjustment

    -3 + 0 - 1 = -4

Therefore:

    26 eligible rows
        - 4 retry adjustment
        = 22

### ✅ Result

    target_base = 22

---

# 7.9 — Edge-Case Stress Test

The logic was evaluated against important hypothetical cases.

---

## Edge Case 1 — More Than Two Retry Levels

Example:

    A
     ↓
    B
     ↓
    C
     ↓
    D

### Expected Behavior

All campaigns should map to the same root campaign.

The recursive CTE supports this.

### ✅ Result

Handled.

---

## Edge Case 2 — Same Customer Repeated Within a Retry Family

Example:

    Customer X
        ↓
    Original campaign → failed
        ↓
    Retry campaign → failed
        ↓
    Retry campaign → delivered

### Expected Behavior

All attempts count as:

    1 underlying communication

because the campaigns belong to one retry family.

### ✅ Result

Handled using:

    COUNT(DISTINCT customer_id)

---

## Edge Case 3 — Different Customers Within a Retry Family

Example:

    Customer A → original
    Customer B → original
    Customer C → retry

### Expected Behavior

Each customer represents a separate underlying communication.

Therefore:

    A = 1
    B = 1
    C = 1

Total:

    3

### ✅ Result

Handled by distinct customer counting within the retry family.

---

## Edge Case 4 — Same Customer Repeated in a Standalone Campaign

Example:

    Customer X → standalone event 1
    Customer X → standalone event 2

### Expected Behavior

Both events must count.

    2 rows → 2 communications

### ✅ Result

Handled using:

    COUNT(*)

for standalone campaigns.

---

## Edge Case 5 — Ineligible Campaign With Communication Logs

Example:

    Campaign → approval_awaiting
    Communication logs → present

### Expected Behavior

The campaign's communication records should not enter the official reporting base.

### Dataset Example

    9004 → approval_awaiting

### ✅ Result

Correctly excluded.

---

## Edge Case 6 — Failed Retry Without a Successful Delivery

A retry family does not require a successful delivery in order to identify the family.

If multiple eligible campaign attempts belong to the same customer and retry chain, they represent one underlying communication according to the retry-family rule.

### ✅ Result

The counting logic is based on campaign-family membership and customer identity, not solely on `delivery_status`.

---

# 7.10 — Final SQL Integrity Check

The final query was reviewed for:

- 🔗 Correct joins
- 🧬 Recursive hierarchy handling
- 🚫 Correct eligibility filtering
- 👤 Correct customer deduplication
- 📦 Correct standalone handling
- 🧮 Correct grouping
- 🕐 Correct date boundaries
- 🧱 Correct CTE structure
- 📊 Correct final aggregation

## Date Boundary

The query uses:

    sent_time >= '2026-10-01'
    AND sent_time < '2026-11-01'

This correctly covers the entire month of October.

## Deduplication

Deduplication is limited to retry families.

## Standalone Events

Standalone events are counted individually.

## Final Aggregation

Family-level counts are summed:

    10 + 7 + 5 = 22

### ✅ Result

The SQL is logically consistent with the assignment's business rules and the observed dataset.

---

# 🧠 Phase 7 Key Findings

The validation confirmed several important analytical principles.

## 1. Raw rows are not automatically communications

    30 raw logs ≠ 30 target communications

Some rows represent retry attempts.

---

## 2. Distinct customers cannot be used globally

A global:

    COUNT(DISTINCT customer_id)

would incorrectly collapse legitimate standalone events.

---

## 3. Retry family membership is essential

The campaign hierarchy determines whether repeated customer records should be treated as retries.

---

## 4. Delivery status alone is insufficient

A failed communication may later be retried.

Therefore, the campaign relationship must be considered.

---

## 5. Multi-level retries must be supported

The chain:

    9001 → 9002 → 9003

cannot be reliably handled with only one level of self-join.

---

# 🧮 Final Validation Bridge

    30 RAW LOGS
          ↓
    0 scope adjustment
          ↓
    30 SCOPED LOGS
          ↓
    -4 ineligible records from 9004
          ↓
    26 ELIGIBLE LOGS
          ↓
    -3 retry-family reduction from 9001
          ↓
    23
          ↓
    +0 standalone adjustment from 9101
          ↓
    23
          ↓
    -1 retry-family reduction from 9201
          ↓
    22 TARGET_BASE

---

# 🏆 Phase 7 Final Result

## Expected by Finance

    target_base = 22

## Produced by Final SQL

    target_base = 22

## Status

**✅ EXACT MATCH**

---

# 🎯 Phase 7 Sign-Off

| Validation Area | Status |
|---|---|
| Reconciliation | ✅ PASS |
| Family-level counts | ✅ PASS |
| Recursive retry chain | ✅ PASS |
| Customer deduplication | ✅ PASS |
| Eligibility filtering | ✅ PASS |
| Standalone handling | ✅ PASS |
| Multi-level retry | ✅ PASS |
| Adjustment calculation | ✅ PASS |
| Edge-case review | ✅ PASS |
| SQL integrity | ✅ PASS |

# 🟢 PHASE 7 — 100% COMPLETE

The SQL solution has been validated against the dataset and the key business-rule edge cases.

Final verified result:

**`target_base = 22`**

---

# 🚀 NEXT PHASE

## PHASE 8 — GITHUB SUBMISSION

Next steps:

1. 📁 Final project structure
2. 📝 Final README
3. 🗃️ Final SQL file
4. 🚫 `.gitignore`
5. 🔐 Ensure `.venv` is not committed
6. 📤 GitHub repository preparation
7. 💾 Git commit
8. 🚀 GitHub push
9. 🔍 Final submission audit
"""