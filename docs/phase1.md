# 🔎 Phase 1 — Raw Data Reconnaissance

## 🎯 Objective

Before applying any business logic, I inspected the raw SQLite database to understand the structure and characteristics of the data.

The purpose of this phase was **observation and investigation only**.

> ⚠️ No records were deleted, modified, deduplicated, or manually cleaned during this phase.

The main questions were:

- How many campaigns exist?
- How many communication-log records exist?
- Which merchant(s) are present?
- What is the date range?
- Which communication types exist?
- What delivery statuses exist?
- Which campaigns are eligible/ineligible?
- Which campaigns are retries?
- Which campaigns are standalone?
- Which customers appear multiple times?
- Are repeated records always duplicates?

---

## 1️⃣ Campaign Count

### SQL

    SELECT COUNT(*) AS campaign_count
    FROM campaign;

### Result

    campaign_count
    --------------
    7

### 💡 Insight

The database contains **7 campaign records** before applying any eligibility or retry logic.

---

## 2️⃣ Communication Log Count

### SQL

    SELECT COUNT(*) AS communication_log_count
    FROM communication_log;

### Result

    communication_log_count
    -----------------------
    30

### 💡 Insight

There are **30 raw communication-log rows**.

This is only the starting population.

It cannot automatically be treated as the official `target_base` because:

1. Some communication logs may belong to ineligible campaigns.
2. Retry attempts can represent the same underlying communication.
3. Repeated sends in a standalone campaign may legitimately count separately.

---

## 3️⃣ Campaign Merchant Distribution

### SQL

    SELECT
        merchant_id,
        COUNT(*) AS campaign_count
    FROM campaign
    GROUP BY merchant_id
    ORDER BY merchant_id;

### Result

    merchant_id | campaign_count
    ------------ | --------------
    501          | 7

### 💡 Insight

All **7 campaigns belong to merchant `501`**.

Therefore, the campaign table contains no campaigns belonging to another merchant.

### 🧠 SQL Note

`GROUP BY merchant_id` groups campaigns by merchant.

`COUNT(*)` counts the campaigns in each group.

`ORDER BY merchant_id` only controls the display order.

---

## 4️⃣ Communication Log Merchant Distribution

### SQL

    SELECT
        merchant_id,
        COUNT(*) AS log_count
    FROM communication_log
    GROUP BY merchant_id
    ORDER BY merchant_id;

### Result

    merchant_id | log_count
    ------------ | ---------
    501          | 30

### 💡 Insight

All **30 communication-log records belong to merchant `501`**.

Therefore, the merchant scope is consistent across both tables.

---

## 5️⃣ Communication Date Range

### SQL

    SELECT
        MIN(sent_time) AS earliest_sent_time,
        MAX(sent_time) AS latest_sent_time
    FROM communication_log;

### Result

    earliest_sent_time  | latest_sent_time
    -------------------- | -------------------
    2026-10-03 10:00:00 | 2026-10-20 10:00:00

### 💡 Insight

The communication logs span:

    2026-10-03 → 2026-10-20

The dataset therefore falls within the assignment's **October 2026** reporting period.

---

## 6️⃣ Communication Type Distribution

### SQL

    SELECT
        communication_type,
        COUNT(*) AS log_count
    FROM communication_log
    GROUP BY communication_type
    ORDER BY communication_type;

### Result

    communication_type | log_count
    ------------------- | ---------
    '2'                 | 30

### 💡 Insight

All **30 communication-log rows have `communication_type = '2'`**.

According to the data dictionary:

    communication_type = '2' → Campaign

Therefore, communication type does not remove any rows from this dataset.

---

## 7️⃣ Delivery Status Distribution

### SQL

    SELECT
        delivery_status,
        COUNT(*) AS log_count
    FROM communication_log
    GROUP BY delivery_status
    ORDER BY delivery_status;

### Result

    delivery_status | log_count
    ---------------- | ---------
    900              | 26
    1100             | 4

### 💡 Insight

The raw communication logs contain:

    900  → 26 records
    1100 → 4 records

Total:

    26 + 4 = 30

According to the data dictionary:

    900  → Delivered successfully
    1100 → Failed / soft failure

The failed records are important because they may later be followed by retry attempts.

Therefore, simply counting successful deliveries is not sufficient to determine the official `target_base`.

---

## 8️⃣ Creation Status Distribution

### SQL

    SELECT
        creation_status,
        COUNT(*) AS campaign_count
    FROM campaign
    GROUP BY creation_status
    ORDER BY creation_status;

### Result

    creation_status    | campaign_count
    ------------------- | --------------
    approved            | 6
    approval_awaiting   | 1

### 💡 Insight

There are:

    approved          → 6 campaigns
    approval_awaiting → 1 campaign

The business rule states that official reporting includes campaigns whose:

    creation_status IN (
        'approved',
        'aborted',
        'resumed',
        'stopped'
    )

Therefore:

    approval_awaiting → NOT ELIGIBLE

However, the important observation is that an `approval_awaiting` campaign can still have communication-log records.

Therefore, campaign eligibility must be checked by joining the campaign table with the communication-log table rather than assuming every logged communication belongs to an eligible campaign.

---

## 9️⃣ Processing Status Distribution

### SQL

    SELECT
        processing_status,
        COUNT(*) AS campaign_count
    FROM campaign
    GROUP BY processing_status
    ORDER BY processing_status;

### Result

    processing_status | campaign_count
    ------------------ | --------------
    processed          | 7

### 💡 Insight

All **7 campaigns have `processing_status = 'processed'`**.

Therefore, processing status does not exclude any campaign in this dataset.

The final eligibility condition still requires:

    creation_status IN (
        'approved',
        'aborted',
        'resumed',
        'stopped'
    )
    AND
    processing_status = 'processed'

---

## 🔟 Campaign Parent-Child Relationships

### SQL

    SELECT
        id,
        parent_id,
        name
    FROM campaign
    ORDER BY id;

### Result

    id   | parent_id | name
    -----|-----------|--------------------------------------------
    9001 | NULL      | Diwali Cart Recovery - Wave 1
    9002 | 9001      | Diwali Cart Recovery - Retry A
    9003 | 9002      | Diwali Cart Recovery - Retry B
    9004 | 9001      | Diwali Cart Recovery - Retry C (pending)
    9101 | NULL      | Diwali Flash Sale - Standalone
    9201 | NULL      | Diwali Wave 2
    9202 | 9201      | Diwali Wave 2 - Retry

### 💡 Insight

The campaign table reveals two retry families and one standalone campaign.

    Family A:

    9001
    ├── 9002
    │   └── 9003
    └── 9004

    Standalone:

    9101

    Family B:

    9201
    └── 9202

The important observation is that retry chains can contain **more than two campaign levels**.

For example:

    9001 → 9002 → 9003

Therefore, retry handling cannot simply compare one campaign with its immediate parent. The analysis must eventually identify the **root campaign / underlying communication family**.

---

## 1️⃣1️⃣ Parent → Child Counts

### SQL

    SELECT
        parent_id,
        COUNT(*) AS child_count
    FROM campaign
    WHERE parent_id IS NOT NULL
    GROUP BY parent_id
    ORDER BY parent_id;

### Result

    parent_id | child_count
    ---------- | -----------
    9001       | 2
    9002       | 1
    9201       | 1

### 💡 Insight

Campaign `9001` has two direct children:

    9002
    9004

Campaign `9002` has one child:

    9003

Campaign `9201` has one child:

    9202

This confirms that the campaign hierarchy is not simply a flat list.

---

## 1️⃣2️⃣ Identify Standalone Campaigns

### SQL

    SELECT
        c.id,
        c.name
    FROM campaign c
    WHERE c.parent_id IS NULL
      AND NOT EXISTS (
          SELECT 1
          FROM campaign child
          WHERE child.parent_id = c.id
      )
    ORDER BY c.id;

### Result

    id   | name
    -----|--------------------------------
    9101 | Diwali Flash Sale - Standalone

### 💡 Insight

Campaign `9101` is the only true standalone campaign.

It satisfies both conditions:

    parent_id IS NULL
    AND
    no other campaign points to it

This is important because the business rule treats standalone campaigns differently from retry families.

For a standalone campaign, repeated sends to the same customer can represent **separate legitimate communication events**.

Therefore, repeated customer records should not automatically be deduplicated.

---

## 1️⃣3️⃣ Customers Appearing Multiple Times

### SQL

    SELECT
        customer_id,
        COUNT(*) AS log_count
    FROM communication_log
    GROUP BY customer_id
    HAVING COUNT(*) > 1
    ORDER BY log_count DESC, customer_id;

### Result

    customer_id | log_count
    ------------ | ---------
    C3           | 3
    C2           | 2
    C20          | 2
    D1           | 2

### 💡 Insight

Four customers appear multiple times:

    C3  → 3 records
    C2  → 2 records
    C20 → 2 records
    D1  → 2 records

At first glance, these may look like duplicate customers.

However, the data dictionary explicitly states that repeated customer records can have different meanings.

Therefore, each repeated customer must be investigated individually.

---

## 1️⃣4️⃣ Investigate Repeated Customer Records

### SQL

    SELECT
        customer_id,
        communication_id,
        delivery_status,
        sent_time
    FROM communication_log
    WHERE customer_id IN ('C2', 'C3', 'C20', 'D1')
    ORDER BY customer_id, sent_time;

### Result

    customer_id | communication_id | delivery_status | sent_time
    ------------ | ---------------- | --------------- | -------------------
    C2           | 9001             | 1100            | 2026-10-03 10:00:00
    C2           | 9002             | 900             | 2026-10-04 10:00:00

    C3           | 9001             | 1100            | 2026-10-03 10:00:00
    C3           | 9002             | 1100            | 2026-10-04 10:00:00
    C3           | 9003             | 900             | 2026-10-05 10:00:00

    C20          | 9101             | 900             | 2026-10-10 10:00:00
    C20          | 9101             | 900             | 2026-10-20 10:00:00

    D1           | 9201             | 1100            | 2026-10-07 10:00:00
    D1           | 9202             | 900             | 2026-10-08 10:00:00

### 💡 Insight

The repeated customers reveal three different situations.

### C2 — Retry

    9001 → failed
    9002 → delivered

Because `9002` is a retry of `9001`, these represent the **same underlying communication**.

Therefore, they should eventually contribute:

    1 underlying communication

rather than:

    2 communications

---

### C3 — Multi-Level Retry

    9001 → failed
    9002 → failed
    9003 → delivered

The retry chain is:

    9001 → 9002 → 9003

All three attempts belong to the same underlying communication.

Therefore:

    3 raw log rows
    ↓
    1 underlying communication

This is a key reason why the final `target_base` cannot be obtained by simply counting log rows.

---

### C20 — Legitimate Repeated Standalone Sends

    9101 → delivered → Oct 10
    9101 → delivered → Oct 20

Campaign `9101` is a true standalone campaign.

Therefore, these are **two legitimate communication events**, not a retry.

They must remain:

    2 communications

This is a critical distinction:

> Repeated customer ≠ duplicate automatically.

---

### D1 — Retry

    9201 → failed
    9202 → delivered

Because `9202` is a retry of `9201`, these represent the same underlying communication.

Therefore:

    2 raw log rows
    ↓
    1 underlying communication

---

## 1️⃣5️⃣ Investigate the Ineligible Campaign

### SQL

    SELECT
        communication_id,
        COUNT(*) AS log_count
    FROM communication_log
    WHERE communication_id = 9004
    GROUP BY communication_id;

### Result

    communication_id | log_count
    ---------------- | ---------
    9004             | 4

### 💡 Insight

Campaign `9004` has **4 communication-log records**.

However:

    creation_status = approval_awaiting
    processing_status = processed

Because `approval_awaiting` is not part of the finalized creation-status set, campaign `9004` is **not eligible for official reporting**.

Therefore, its 4 communication-log rows must be excluded from the official target-base calculation.

This is an important finding because the raw communication-log table contains records that do not belong to the official reporting population.

---

# 🧠 Phase 1 Key Findings

After raw-data reconnaissance, the following facts are established:

### 📊 Raw Dataset

    Campaigns:              7
    Communication logs:    30
    Merchant:              501
    Communication type:    '2'
    Date range:            Oct 3–Oct 20, 2026

### 📊 Delivery Status

    Delivered (900):       26
    Failed (1100):          4

### 📊 Campaign Eligibility

    Approved:               6
    Approval-awaiting:      1
    Processed:              7

### 🔗 Retry Families

    Family A:
    9001 → 9002 → 9003

    Pending/ineligible child:
    9004 → parent 9001

    Family B:
    9201 → 9202

    Standalone:
    9101

### 👥 Repeated Customers

    C2  → retry
    C3  → multi-level retry
    C20 → legitimate repeated standalone sends
    D1  → retry

---

# 🚨 Most Important Phase 1 Insight

The raw count of:

    30 communication-log rows

cannot be used directly as the official `target_base`.

There are **two different mechanisms affecting the count**:

### 1. Campaign eligibility

Campaign `9004` is `approval_awaiting`, so its 4 communication-log rows are not eligible.

    30
    ↓
    26 eligible log rows

### 2. Retry chains

Some eligible log rows represent multiple attempts of the same underlying communication.

For example:

    C3:
    9001 → 9002 → 9003

These three attempts must eventually collapse into **one underlying communication**.

At the same time, `C20` appears twice in standalone campaign `9101`, and those two records must remain separate.

Therefore:

> The correct solution requires **business-rule-based reconciliation**, not generic duplicate removal.

---

# 🔍 Phase 1 Conclusion

The database is internally consistent, but the raw communication-log count is intentionally different from the official Finance target.

The investigation shows that the final calculation must account for:

1. Merchant scope
2. October 2026 date scope
3. Communication type `2`
4. Eligible campaign creation status
5. Processed campaign status
6. Retry relationships through `parent_id`
7. Multi-level retry chains
8. Distinct customers within retry families
9. Legitimate repeated sends in standalone campaigns

### 🎯 Next Phase

**Phase 2 — Naive Baseline**

The next step is to deliberately calculate the simplest/naive version of the target base.

We will then compare that number with Finance's expected:

    target_base = 22

and use the difference to build the reconciliation bridge.

> ⚠️ We should NOT jump directly to the final query. The purpose of the assignment is to demonstrate how the raw count is reconciled to 22 through explicit business-rule adjustments.