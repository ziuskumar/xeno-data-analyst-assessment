# 🔥 PHASE 4 — RETRY / CAMPAIGN LOGIC

## 🎯 Objective

The objective of Phase 4 was to convert the investigation from Phase 3 into a formal and reproducible business counting rule.

The main question was:

> How should communication-log rows be counted when campaigns have retry relationships?

Finance expects the final `target_base` for:

- Merchant: `501`
- Month: October 2026
- Communication Type: `2`

to be:

**22**

Phase 4 establishes:

1. How retry families are identified.
2. How multi-level retry chains are handled.
3. How communication logs are mapped to retry families.
4. How retry attempts are separated from legitimate repeated sends.
5. How standalone campaigns are treated.
6. The final counting rule.
7. Edge-case validation.

---

# 4.1 — DEFINE A RETRY FAMILY

## 🎯 Objective

Understand campaign relationships using the `parent_id` column.

A retry campaign points to its previous campaign through:

`campaign.parent_id`

## SQL

    SELECT
        c.id AS campaign_id,
        c.name AS campaign_name,
        c.parent_id,
        p.name AS parent_campaign_name
    FROM campaign c
    LEFT JOIN campaign p
        ON c.parent_id = p.id
    ORDER BY c.id;

## Result

    9001 | Diwali Cart Recovery - Wave 1
    9002 | Diwali Cart Recovery - Retry A
         | parent = 9001

    9003 | Diwali Cart Recovery - Retry B
         | parent = 9002

    9004 | Diwali Cart Recovery - Retry C (pending)
         | parent = 9001

    9101 | Diwali Flash Sale - Standalone
         | parent = NULL

    9201 | Diwali Wave 2
         | parent = NULL

    9202 | Diwali Wave 2 - Retry
         | parent = 9201

## Campaign Hierarchy

    Family A

    9001
    ├── 9002
    │   └── 9003
    └── 9004


    Standalone

    9101


    Family B

    9201
    └── 9202

## Important Observation

Campaign `9004` is structurally part of the `9001` retry family.

However:

    9004.creation_status = approval_awaiting

Therefore, its communication-log records are not eligible for official reporting.

This establishes an important distinction:

    Campaign hierarchy ≠ Reporting eligibility

A campaign may belong to a retry family but still be excluded from the reporting calculation.

---

# 4.2 — ATTACH EVERY CAMPAIGN TO ITS RETRY FAMILY

## 🎯 Why?

A retry chain can contain multiple levels.

Example:

    9001 → 9002 → 9003

Checking only the immediate parent would not be sufficient.

A recursive CTE was therefore used to identify the root campaign for every campaign.

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
    SELECT
        campaign_id,
        parent_id,
        root_campaign_id
    FROM campaign_tree
    ORDER BY campaign_id;

## Result

    campaign_id | parent_id | root_campaign_id
    ------------|-----------|----------------
    9001        | NULL      | 9001
    9002        | 9001      | 9001
    9003        | 9002      | 9001
    9004        | 9001      | 9001
    9101        | NULL      | 9101
    9201        | NULL      | 9201
    9202        | 9201      | 9201

## Interpretation

    9001 → root 9001
    9002 → root 9001
    9003 → root 9001
    9004 → root 9001

    9101 → root 9101

    9201 → root 9201
    9202 → root 9201

Therefore:

    9001, 9002, 9003, 9004 → Family 9001
    9101                    → Standalone Family 9101
    9201, 9202              → Family 9201

The recursive approach correctly handles retry chains longer than two levels.

---

# 4.3 — ATTACH ELIGIBLE COMMUNICATION LOGS TO FAMILIES

## 🎯 Objective

Map every eligible communication-log record to its retry-family root.

The official reporting rules are:

    merchant_id = 501

    communication_type = '2'

    sent_time >= '2026-10-01'

    sent_time < '2026-11-01'

    creation_status IN
    ('approved', 'aborted', 'resumed', 'stopped')

    processing_status = 'processed'

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
    ),
    eligible_logs AS (
        SELECT
            cl.customer_id,
            cl.communication_id,
            ct.root_campaign_id,
            cl.delivery_status,
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
    )
    SELECT
        customer_id,
        communication_id,
        root_campaign_id,
        delivery_status,
        sent_time
    FROM eligible_logs
    ORDER BY
        root_campaign_id,
        customer_id,
        sent_time;

## Observation

All eligible communication-log records mapped to:

    9001 family
    9101 standalone
    9201 family

The four records belonging to campaign `9004` did not appear because:

    9004.creation_status = 'approval_awaiting'

Therefore:

    9004 is structurally in Family 9001
    BUT
    9004 is not part of the official reporting population.

---

# 4.4 — IDENTIFY UNDERLYING COMMUNICATIONS

## 🎯 Key Question

Does every communication-log row represent a separate communication?

    NO

A customer may appear multiple times because of retry attempts.

However, a customer may also legitimately appear multiple times within a standalone campaign.

Therefore:

    Repeated customer ≠ duplicate

We need to understand the campaign family before deciding how repeated records should be counted.

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
    ),
    eligible_logs AS (
        SELECT
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
    )
    SELECT
        customer_id,
        root_campaign_id,
        COUNT(*) AS attempt_count,
        COUNT(DISTINCT communication_id) AS campaign_count,
        MIN(sent_time) AS first_event,
        MAX(sent_time) AS last_event
    FROM eligible_logs
    GROUP BY
        customer_id,
        root_campaign_id
    ORDER BY
        root_campaign_id,
        customer_id;

## Result

    customer_id | root_campaign_id | attempt_count | campaign_count
    ------------|------------------|---------------|----------------
    C1          | 9001             | 1             | 1
    C10         | 9001             | 1             | 1
    C2          | 9001             | 2             | 2
    C3          | 9001             | 3             | 3
    C4          | 9001             | 1             | 1
    C5          | 9001             | 1             | 1
    C6          | 9001             | 1             | 1
    C7          | 9001             | 1             | 1
    C8          | 9001             | 1             | 1
    C9          | 9001             | 1             | 1

    C20         | 9101             | 2             | 1
    C21         | 9101             | 1             | 1
    C22         | 9101             | 1             | 1
    C23         | 9101             | 1             | 1
    C24         | 9101             | 1             | 1
    C25         | 9101             | 1             | 1

    D1          | 9201             | 2             | 2
    D2          | 9201             | 1             | 1
    D3          | 9201             | 1             | 1
    D4          | 9201             | 1             | 1
    D5          | 9201             | 1             | 1

## Important Findings

### C2

    9001 → failed
    9002 → delivered

    2 log rows
    2 campaign IDs
    1 underlying communication

Adjustment:

    -1

---

### C3

    9001 → failed
    9002 → failed
    9003 → delivered

    3 log rows
    3 campaign IDs
    1 underlying communication

Adjustment:

    -2

This is a multi-level retry chain.

---

### D1

    9201 → failed
    9202 → delivered

    2 log rows
    2 campaign IDs
    1 underlying communication

Adjustment:

    -1

---

### C20

    9101 → delivered
    9101 → delivered

    2 log rows
    1 campaign ID

These are two legitimate sends from the same standalone campaign.

Therefore:

    2 log rows
    → 2 communication events

Adjustment:

    0

This is the critical counterexample showing why simply using:

    COUNT(DISTINCT customer_id)

for all records would be incorrect.

---

# 4.5 — SEPARATE RETRY FAMILIES FROM STANDALONE CAMPAIGNS

## 🎯 Objective

Explicitly identify which campaign roots contain retries.

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
    SELECT
        root_campaign_id,
        COUNT(*) AS campaigns_in_family,
        COUNT(*) - 1 AS retry_campaigns
    FROM campaign_tree
    GROUP BY root_campaign_id
    ORDER BY root_campaign_id;

## Result

    root_campaign_id | campaigns_in_family | retry_campaigns
    ------------------|---------------------|----------------
    9001              | 4                   | 3
    9101              | 1                   | 0
    9201              | 2                   | 1

## Interpretation

### Family 9001

    4 campaigns
    3 non-root campaigns

Structure:

    9001
    ├── 9002
    │   └── 9003
    └── 9004

Note:

`9004` is structurally part of this family but its logs are excluded by reporting eligibility.

---

### Family 9101

    1 campaign
    0 retry campaigns

Therefore:

    STANDALONE

---

### Family 9201

    2 campaigns
    1 retry campaign

Structure:

    9201
    └── 9202

Therefore:

    RETRY FAMILY

---

# 4.6 — CREATE THE COUNTING RULE

## 🎯 Business Rule

The campaign family determines how communication-log records are counted.

### Retry Family

For a retry family:

    COUNT(DISTINCT customer_id)

Reason:

Multiple campaign attempts against the same customer represent one underlying communication.

Example:

    C3
    9001 → failed
    9002 → failed
    9003 → delivered

The three rows represent:

    1 underlying communication

Therefore:

    3 → 1

---

### Standalone Campaign

For a standalone campaign:

    COUNT(*)

Reason:

Multiple sends from the same standalone campaign are legitimate separate communication events.

Example:

    C20
    9101 → delivered
    9101 → delivered

The two rows represent:

    2 legitimate communication events

Therefore:

    2 → 2

---

## Final Counting Query

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
    END AS counted_communications
FROM eligible_logs el
JOIN family_type ft
    ON el.root_campaign_id = ft.root_campaign_id
GROUP BY
    el.root_campaign_id,
    family_type
ORDER BY
    el.root_campaign_id;

    .

🧠 Phase 4 — Final Business Logic

The complete counting logic is:

1. Restrict to merchant 501.

2. Restrict to October 2026.

3. Restrict to communication_type = '2'.

4. Join communication logs to campaigns.

5. Keep only campaigns with:
       creation_status IN
       ('approved', 'aborted', 'resumed', 'stopped')

6. Require:
       processing_status = 'processed'

7. Build campaign retry families using parent_id recursively.

8. Map every eligible communication-log row to its root campaign.

9. Determine whether the root represents:
       a) a retry family
       b) a standalone campaign

10. For retry families:
        COUNT(DISTINCT customer_id)

11. For standalone campaigns:
        COUNT(*)

12. Sum the family-level counts.

13. Final target_base = 22
📊 Phase 4 — Final Validation
Root Campaign	Type	Eligible Rows	Counted Communications
9001	Retry Family	13	10
9101	Standalone	7	7
9201	Retry Family	6	5
TOTAL		26	22
🔍 Why COUNT(DISTINCT customer_id) Alone Is Wrong

A tempting solution would be:

SELECT COUNT(DISTINCT customer_id)
FROM communication_log;

But this would produce:

21

The Finance target is:

22

Why?

Because customer C20 appears twice in standalone campaign 9101.

Those two records are legitimate separate communication events.

Therefore:

Distinct customers = 21
Actual target base = 22

The correct logic must understand campaign retry structure before deciding how to count.

🧠 Key Analytical Insight

The most important discovery from Phase 4 is:

A repeated customer is not automatically a duplicate communication.

There are two fundamentally different situations:

Retry-linked repetition
Customer
   ↓
Original Campaign
   ↓
Retry Campaign
   ↓
Another Retry

These represent attempts toward the same underlying communication.

Therefore:

Collapse to one customer-level communication
Standalone repetition
Customer
   ↓
Same Standalone Campaign
   ↓
Another legitimate send

These are separate communication events.

Therefore:

Do NOT collapse

The campaign hierarchy provides the business context required to distinguish the two.

⚠️ Important Lesson

Do not solve this problem using only:

DISTINCT customer_id

and do not solve it using only:

DISTINCT communication_id

The correct unit of counting depends on the campaign's role:

Retry Family
    → one customer across the family = one underlying communication

Standalone Campaign
    → every communication-log row = one communication event

This is why the campaign hierarchy and parent_id relationship are central to the solution.

📝 Phase 4 Conclusion

Phase 4 successfully converted the exploratory findings from Phase 3 into a formal business rule.

The final eligible population is:

26 eligible communication-log rows

These are converted into:

9001 retry family → 10 communications
9101 standalone   → 7 communications
9201 retry family → 5 communications

Therefore:

10 + 7 + 5 = 22

Final result:

target_base = 22

Phase 4 is therefore:

✅ 100% COMPLETE