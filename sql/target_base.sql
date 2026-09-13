-- Xeno Data Analyst Internship
-- Finance target_base reconciliation
-- Merchant: 501
-- Period: October 2026
-- Communication type: Campaign (2)

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
