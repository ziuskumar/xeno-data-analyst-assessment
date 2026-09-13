# Xeno Data Analyst Internship — Comm-Log Reconciliation

## 🎯 Objective

This repository contains the solution for the **Xeno Data Analyst Internship take-home assignment**.

The objective is to reconcile Finance's expected:

    target_base = 22

for:

- **Merchant:** `501`
- **Period:** October 2026
- **Communication Type:** `2` — Campaign
- **Campaign Scope:** Diwali campaigns

The key challenge is distinguishing between individual communication attempts, underlying communications, retry campaigns, standalone campaign events, and campaigns that are not yet eligible for official reporting.

---

## 🧠 Problem Understanding

A naive approach counts every row in `communication_log` as one communication.

The naive count is:

    30

Finance expects:

    22

The reconciliation requires identifying:

1. 🚫 Campaigns that are not eligible for official reporting.
2. 🔄 Retry campaigns where multiple attempts represent the same underlying communication.
3. 🟢 Standalone campaigns where repeated sends are legitimate independent events.

---

## 🗂️ Dataset

The SQLite database is located at:

    data/comm_log.db

CSV versions are also provided:

    data/campaign.csv
    data/communication_log.csv

The database contains:

    campaign
    communication_log

---

## 📋 `campaign` Table

| Column | Meaning |
|---|---|
| `id` | Campaign ID |
| `merchant_id` | Merchant owning the campaign |
| `parent_id` | Parent campaign ID when the campaign is a retry |
| `name` | Campaign name |
| `creation_status` | Campaign creation/approval status |
| `processing_status` | Campaign processing status |

### Eligible Creation Statuses

The following statuses are considered finalized/live:

    approved
    aborted
    resumed
    stopped

The following status is not eligible:

    approval_awaiting

A campaign must also have:

    processing_status = 'processed'

---

## 📋 `communication_log` Table

| Column | Meaning |
|---|---|
| `id` | Send-attempt ID |
| `merchant_id` | Merchant owning the communication |
| `communication_id` | Related campaign ID |
| `customer_id` | Target customer |
| `communication_type` | `2` represents Campaign |
| `delivery_status` | Delivery result |
| `sent_time` | Time the communication was sent |
| `scheduled_time` | Scheduled send time |
| `credit_used` | Credits consumed |
| `channel` | Communication channel |

### Delivery Status

    900  = delivered
    1100 = failed / soft failure

---

## 🎯 Scope

The analysis uses:

    merchant_id = 501

    communication_type = '2'

and October 2026:

    sent_time >= '2026-10-01'
    AND sent_time < '2026-11-01'

Campaign eligibility is:

    creation_status IN (
        'approved',
        'aborted',
        'resumed',
        'stopped'
    )
    AND processing_status = 'processed'

---

## 🔄 Retry Logic

A campaign becomes a retry when its:

    parent_id

points to another campaign.

For example:

    9001
      ↓
    9002
      ↓
    9003

represents one retry family.

A customer who appears in multiple campaigns within the same retry family was targeted by the same underlying communication.

Therefore, for retry families:

    COUNT(DISTINCT customer_id)

is used.

Retry chains can contain more than two campaign levels, so the final SQL uses a recursive CTE to identify the root campaign.

---

## 🟢 Standalone Logic

A campaign with:

- no parent campaign, and
- no child campaign

is treated as a standalone campaign.

For standalone campaigns, every send is an independent communication event.

Therefore:

    COUNT(*)

is used.

This distinction matters because the same customer can legitimately receive multiple independent sends from a standalone campaign.

Example:

    Customer C20
        ↓
    Campaign 9101
        ↓
    Oct 10 → delivered
    Oct 20 → delivered

These are counted as:

    2 communications

not:

    1 communication

---

# 🔎 Investigation

## 1. Raw Data

Campaign records:

    SELECT COUNT(*) AS campaign_count
    FROM campaign;

Result:

    7

Communication-log records:

    SELECT COUNT(*) AS communication_log_count
    FROM communication_log;

Result:

    30

---

## 2. Naive Baseline

The obvious first approach is to count every communication-log row:

    SELECT COUNT(*) AS naive_count
    FROM communication_log;

Result:

    30

---

## 3. Scope Filtering

The assignment scope is:

- Merchant `501`
- Communication type `2`
- October 2026

    SELECT COUNT(*) AS scoped_count
    FROM communication_log
    WHERE merchant_id = 501
      AND communication_type = '2'
      AND sent_time >= '2026-10-01'
      AND sent_time < '2026-11-01';

Result:

    30

No rows are removed at the scope stage.

---

## 4. Campaign Eligibility

Applying campaign eligibility:

    SELECT COUNT(*) AS eligible_count
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

Result:

    26

The four excluded records belong to campaign:

    9004

Campaign `9004` has:

    creation_status = approval_awaiting

Therefore it is not eligible for official reporting.

---

# 🌳 Campaign Hierarchy

The campaign hierarchy is:

    9001
    ├── 9002
    │   └── 9003
    └── 9004

    9101

    9201
    └── 9202

Campaign `9004` is structurally part of the `9001` family, but its four communication-log rows are excluded because it is still `approval_awaiting`.

---

# 🔍 Retry-Family Analysis

## Retry Family `9001`

Eligible communication-log rows:

    13

Distinct customers:

    10

Therefore:

    13 → 10

Adjustment:

    -3

Examples:

    C2:
    9001 failed
    9002 delivered

    C3:
    9001 failed
    9002 failed
    9003 delivered

C2 represents one underlying communication.

C3 represents one underlying communication despite three campaign attempts.

---

## Standalone Campaign `9101`

Eligible records:

    7

Counted communications:

    7

Adjustment:

    0

Customer `C20` appears twice:

    Oct 10
    Oct 20

Because `9101` is standalone, these are two legitimate independent communication events.

Therefore:

    7 → 7

---

## Retry Family `9201`

Eligible communication-log rows:

    6

Distinct customers:

    5

Therefore:

    6 → 5

Adjustment:

    -1

Example:

    D1:
    9201 failed
    9202 delivered

These are two attempts within the same retry family and therefore count as one underlying communication.

---

# 📊 Reconciliation Bridge

| Stage | Count | Adjustment | Reason |
|---|---:|---:|---|
| Raw communication-log rows | 30 | — | Initial row-level count |
| Reporting scope | 30 | 0 | Merchant, type and date filters |
| Eligible campaigns | 26 | -4 | Exclude `approval_awaiting` campaign `9004` |
| Retry family `9001` | 10 | -3 | Collapse repeated customer attempts |
| Standalone campaign `9101` | 7 | 0 | Repeated standalone sends remain independent |
| Retry family `9201` | 5 | -1 | Collapse retry attempts |
| **Final `target_base`** | **22** | **-8 total** | Reconciled with Finance |

The total reduction is:

    -4  eligibility adjustment
    -4  retry-family adjustment
    ------------------------------
    -8  total reduction

Therefore:

    30 - 4 - 4 = 22

---

# 🧮 Final Counting Rule

The final counting rule is:

    IF campaign family contains retries:
        COUNT DISTINCT customers within the family

    IF campaign is standalone:
        COUNT every eligible communication-log row

In SQL terms:

    CASE
        WHEN family_type = 'RETRY_FAMILY'
            THEN COUNT(DISTINCT customer_id)
        ELSE COUNT(*)
    END

This rule reconciles the dataset without incorrectly collapsing legitimate standalone events.

---

# 🧪 Final SQL

The production query is stored in:

    sql/target_base.sql

It uses a recursive CTE to resolve campaign hierarchies.

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

Expected output:

    target_base
    -----------
    22

---

# ▶️ How to Run

## Prerequisites

The project uses a local SQLite database and does not require a database server.

Install:

- **SQLite 3.x**
- **Git**

Python is only required if you want to regenerate the supplied dataset.

---

## 1. Clone the Repository

    git clone https://github.com/ziuskumar/xeno-data-analyst-assessment.git
    cd xeno-data-analyst-assessment

If the repository is cloned into a different directory, simply run the commands from the repository root.

---

## 2. Verify the Database

The database is already included in:

    data/comm_log.db

Open it from the repository root.

### Windows PowerShell

    sqlite3 ".\data\comm_log.db"

### macOS / Linux

    sqlite3 data/comm_log.db

Check the available tables:

    .tables

Expected:

    campaign
    communication_log

Verify the campaign count:

    SELECT COUNT(*) AS campaign_count
    FROM campaign;

Expected:

    7

Verify the communication-log count:

    SELECT COUNT(*) AS communication_log_count
    FROM communication_log;

Expected:

    30

Exit SQLite:

    .quit

---

## 3. Run the Final Reconciliation Query

The final SQL query is stored at:

    sql/target_base.sql

### Windows PowerShell

From the repository root:

    sqlite3 ".\data\comm_log.db" ".read .\sql\target_base.sql"

### macOS / Linux

From the repository root:

    sqlite3 data/comm_log.db ".read sql/target_base.sql"

Expected result:

    target_base
    -----------
    22

This reproduces Finance's expected:

    target_base = 22

---

## 4. Run the Query Interactively

Alternatively, open the database.

### Windows PowerShell

    sqlite3 ".\data\comm_log.db"

### macOS / Linux

    sqlite3 data/comm_log.db

Then execute:

    .read sql/target_base.sql

Expected result:

    target_base
    -----------
    22

---

## 📌 Portability

All project references use **relative paths**:

    data/comm_log.db
    sql/target_base.sql
    data/campaign.csv
    data/communication_log.csv

No machine-specific paths are required.

The README intentionally does **not** reference a local SQLite executable such as:

    C:\Users\<username>\Downloads\...

Therefore, the repository can be cloned to any directory on a Windows, macOS, or Linux machine and executed from the repository root, provided SQLite is installed and available as `sqlite3`.

---

# 🧪 Validation & Edge Cases

The solution was validated against the important edge cases in the dataset.

### Multi-level retry

    9001 → 9002 → 9003

is handled recursively.

### Ineligible retry child

    9004

is part of the `9001` hierarchy but is excluded because:

    creation_status = approval_awaiting

### Repeated customer within retry family

Repeated attempts for the same customer are collapsed using:

    COUNT(DISTINCT customer_id)

### Repeated customer in standalone campaign

Customer `C20` appears twice in standalone campaign `9101`.

Both events remain counted.

### Failed → retry → delivered

A sequence such as:

    failed → delivered

within the same retry family counts as one underlying communication.

---

# 💡 Key Insight

The main analytical insight is that **a communication-log row is not always equivalent to an underlying communication**.

For retry-linked campaigns:

    Multiple attempts
            ↓
    Same customer
            ↓
    Same retry family
            ↓
    One underlying communication

For standalone campaigns:

    Multiple sends
            ↓
    Same campaign
            ↓
    Independent events
            ↓
    Count each event

This distinction allows the calculation to reconcile exactly to Finance's expected:

    target_base = 22

---

# 📁 Project Structure

    xeno-data-analyst-assessment/
    │
    ├── data/
    │   ├── campaign.csv
    │   ├── communication_log.csv
    │   └── comm_log.db
    │
    ├── docs/
    │   ├── phase1.md
    │   ├── phase2.md
    │   ├── phase3.md
    │   ├── phase4.md
    │   ├── phase5.md
    │   ├── phase6.md
    │   └── phase7.md
    │
    ├── scripts/
    │   └── generate_dataset.py
    │
    ├── sql/
    │   └── target_base.sql
    │
    ├── README.md
    └── .gitignore

---

# 📈 Final Result

    Initial communication-log rows: 30

    Less:
        Ineligible campaign records:   -4
        Retry overcount:                -4

    Final target_base:                22

### ✅ Finance Reconciliation

    Expected target_base  = 22
    Calculated target_base = 22

    STATUS: RECONCILED

---

# 🤖 AI Assistance

AI assistance was used during the analysis to:

- structure the investigation workflow,
- reason through SQL logic,
- validate edge cases,
- refine the reconciliation approach, and
- review the final SQL.

The business rules, intermediate results, and final query were tested against the supplied SQLite dataset and can be explained and defended during an interview.

---

# 👤 Author

**Zius Kumar**

This repository was prepared as part of the **Xeno Data Analyst Internship assessment**.