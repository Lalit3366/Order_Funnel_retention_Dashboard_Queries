-- =====================================================================
-- ORDER FUNNEL, FAILURE, RETENTION & BUSINESS INSIGHTS - SQL QUERIES
-- Prepared by: Ishika Aggarwal
-- Tables: orders (481,166 rows), order_details (80,910 rows)
--         order_details.order_id references orders.id
-- Dialect: MySQL 8+ (uses window functions). Reference date = 2026-08-18.
-- =====================================================================


-- =====================================================================
-- 1. ORDER FUNNEL
-- =====================================================================

-- 1.1 Funnel stage counts
SELECT 'Payment Initiated' AS stage, COUNT(*) AS order_count
FROM orders
UNION ALL
SELECT 'Trial Started', COUNT(*)
FROM orders WHERE status = 'SUCCESS'
UNION ALL
SELECT 'Trial Completed', COUNT(*)
FROM orders WHERE status = 'SUCCESS' AND expiry_date <= '2026-08-18'
UNION ALL
SELECT 'Subscription Attempted', COUNT(DISTINCT order_id)
FROM order_details
UNION ALL
SELECT 'Subscription Successful', COUNT(DISTINCT order_id)
FROM order_details WHERE status = 'SUCCESS'
UNION ALL
SELECT 'Failed Orders (trial stage)', COUNT(*)
FROM orders WHERE status = 'FAILED';

-- 1.2 Conversion & drop-off rate between consecutive funnel stages
WITH funnel AS (
    SELECT 1 AS stage_order, 'Payment Initiated' AS stage, COUNT(*) AS cnt FROM orders
    UNION ALL
    SELECT 2, 'Trial Started', COUNT(*) FROM orders WHERE status = 'SUCCESS'
    UNION ALL
    SELECT 3, 'Trial Completed', COUNT(*) FROM orders WHERE status = 'SUCCESS' AND expiry_date <= '2026-08-18'
    UNION ALL
    SELECT 4, 'Subscription Attempted', COUNT(DISTINCT order_id) FROM order_details
    UNION ALL
    SELECT 5, 'Subscription Successful', COUNT(DISTINCT order_id) FROM order_details WHERE status = 'SUCCESS'
)
SELECT
    stage,
    cnt AS order_count,
    ROUND(cnt * 100.0 / LAG(cnt) OVER (ORDER BY stage_order), 2)  AS conversion_pct_from_prev_stage,
    ROUND(100 - (cnt * 100.0 / LAG(cnt) OVER (ORDER BY stage_order)), 2) AS dropoff_pct_from_prev_stage,
    ROUND(cnt * 100.0 / FIRST_VALUE(cnt) OVER (ORDER BY stage_order), 2) AS conversion_pct_from_start
FROM funnel
ORDER BY stage_order;


-- =====================================================================
-- 2. FAILURE ANALYSIS
-- =====================================================================

-- 2.1 Trial-stage failure reasons: count & %
SELECT
    COALESCE(failed_reason, 'NOT_SPECIFIED') AS failure_reason,
    COUNT(*) AS failure_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_all_failures
FROM orders
WHERE status = 'FAILED'
GROUP BY COALESCE(failed_reason, 'NOT_SPECIFIED')
ORDER BY failure_count DESC;

-- 2.2 Subscription-stage failure reasons: count & %
SELECT
    COALESCE(failed_reason, 'NOT_SPECIFIED') AS failure_reason,
    COUNT(*) AS failure_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_all_failures
FROM order_details
WHERE status = 'FAILED'
GROUP BY COALESCE(failed_reason, 'NOT_SPECIFIED')
ORDER BY failure_count DESC;

-- 2.3 Payment gateway-wise failures (trial stage)
SELECT
    payment_gateway,
    COUNT(*) AS total_attempts,
    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) AS failed_count,
    ROUND(SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS failure_pct,
    ROUND(SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS success_pct
FROM orders
WHERE payment_gateway IN ('phonepe', 'paytm', 'razorpay')
GROUP BY payment_gateway
ORDER BY total_attempts DESC;

-- 2.4 Payment gateway-wise failures (subscription stage)
SELECT
    payment_gateway,
    COUNT(*) AS total_attempts,
    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) AS failed_count,
    ROUND(SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS failure_pct
FROM order_details
WHERE payment_gateway IN ('phonepe', 'razorpay')
GROUP BY payment_gateway
ORDER BY total_attempts DESC;

-- 2.5 Top failure categories (trial + subscription stage combined)
SELECT failure_reason, SUM(failure_count) AS total_failures
FROM (
    SELECT COALESCE(failed_reason, 'NOT_SPECIFIED') AS failure_reason, COUNT(*) AS failure_count
    FROM orders WHERE status = 'FAILED'
    GROUP BY COALESCE(failed_reason, 'NOT_SPECIFIED')
    UNION ALL
    SELECT COALESCE(failed_reason, 'NOT_SPECIFIED'), COUNT(*)
    FROM order_details WHERE status = 'FAILED'
    GROUP BY COALESCE(failed_reason, 'NOT_SPECIFIED')
) combined
GROUP BY failure_reason
ORDER BY total_failures DESC
LIMIT 10;


-- =====================================================================
-- 3. USER RETENTION
-- =====================================================================

-- 3.1 Daily active (paying) customers
SELECT DATE(order_date) AS order_day, COUNT(DISTINCT customer_id) AS active_customers
FROM orders
WHERE customer_id IS NOT NULL
GROUP BY DATE(order_date)
ORDER BY order_day;

-- 3.2 Weekly active (paying) customers
SELECT
    DATE_SUB(DATE(order_date), INTERVAL WEEKDAY(order_date) DAY) AS week_start,
    COUNT(DISTINCT customer_id) AS active_customers
FROM orders
WHERE customer_id IS NOT NULL
GROUP BY DATE_SUB(DATE(order_date), INTERVAL WEEKDAY(order_date) DAY)
ORDER BY week_start;

-- 3.3 Monthly cohort retention (% of each first-order-month cohort still ordering N months later)
WITH first_order AS (
    SELECT customer_id, MIN(DATE_FORMAT(order_date, '%Y-%m-01')) AS cohort_month
    FROM orders
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id
),
activity AS (
    SELECT o.customer_id, f.cohort_month, DATE_FORMAT(o.order_date, '%Y-%m-01') AS order_month
    FROM orders o
    JOIN first_order f ON f.customer_id = o.customer_id
),
cohort_activity AS (
    SELECT
        cohort_month,
        TIMESTAMPDIFF(MONTH, cohort_month, order_month) AS month_index,
        COUNT(DISTINCT customer_id) AS active_customers
    FROM activity
    GROUP BY cohort_month, TIMESTAMPDIFF(MONTH, cohort_month, order_month)
),
cohort_size AS (
    SELECT cohort_month, active_customers AS cohort_size
    FROM cohort_activity WHERE month_index = 0
)
SELECT
    ca.cohort_month,
    ca.month_index,
    ca.active_customers,
    cs.cohort_size,
    ROUND(ca.active_customers * 100.0 / cs.cohort_size, 2) AS retention_pct
FROM cohort_activity ca
JOIN cohort_size cs ON cs.cohort_month = ca.cohort_month
ORDER BY ca.cohort_month, ca.month_index;

-- 3.4 New vs Returning users per month
WITH first_order AS (
    SELECT customer_id, MIN(DATE_FORMAT(order_date, '%Y-%m-01')) AS cohort_month
    FROM orders WHERE customer_id IS NOT NULL
    GROUP BY customer_id
)
SELECT
    DATE_FORMAT(o.order_date, '%Y-%m-01') AS order_month,
    SUM(CASE WHEN DATE_FORMAT(o.order_date, '%Y-%m-01') = f.cohort_month THEN 1 ELSE 0 END) AS new_customers,
    SUM(CASE WHEN DATE_FORMAT(o.order_date, '%Y-%m-01') > f.cohort_month THEN 1 ELSE 0 END) AS returning_customers
FROM orders o
JOIN first_order f ON f.customer_id = o.customer_id
GROUP BY DATE_FORMAT(o.order_date, '%Y-%m-01')
ORDER BY order_month;

-- 3.5 Repeat customer rate & repeat subscription rate
SELECT
    COUNT(*) AS total_customers,
    SUM(CASE WHEN order_count > 1 THEN 1 ELSE 0 END) AS repeat_customers,
    ROUND(SUM(CASE WHEN order_count > 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS repeat_customer_pct
FROM (
    SELECT customer_id, COUNT(*) AS order_count
    FROM orders WHERE customer_id IS NOT NULL
    GROUP BY customer_id
) t;

SELECT
    COUNT(*) AS converted_trial_orders,
    SUM(CASE WHEN success_count > 1 THEN 1 ELSE 0 END) AS repeat_subscribers,
    ROUND(SUM(CASE WHEN success_count > 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS repeat_subscription_pct
FROM (
    SELECT order_id, COUNT(*) AS success_count
    FROM order_details WHERE status = 'SUCCESS'
    GROUP BY order_id
) t;


-- =====================================================================
-- 4. BUSINESS INSIGHTS
-- =====================================================================

-- 4.1 Order trends & trial-to-subscription conversion (monthly)
SELECT
    DATE_FORMAT(order_date, '%Y-%m') AS month,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS trials_started,
    ROUND(SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS trial_conversion_pct
FROM orders
GROUP BY DATE_FORMAT(order_date, '%Y-%m')
ORDER BY month;

-- 4.2 Revenue trend (trial revenue + subscription/renewal revenue, monthly)
SELECT
    month,
    SUM(trial_revenue) AS trial_revenue,
    SUM(subscription_revenue) AS subscription_revenue,
    SUM(trial_revenue) + SUM(subscription_revenue) AS total_revenue
FROM (
    SELECT DATE_FORMAT(order_date, '%Y-%m') AS month, amount AS trial_revenue, 0 AS subscription_revenue
    FROM orders WHERE status = 'SUCCESS'
    UNION ALL
    SELECT DATE_FORMAT(created_at, '%Y-%m'), 0, amount
    FROM order_details WHERE status = 'SUCCESS'
) combined
GROUP BY month
ORDER BY month;

-- 4.3 Plan-wise performance
SELECT
    o.plan_id,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN o.status = 'SUCCESS' THEN 1 ELSE 0 END) AS trials_started,
    ROUND(SUM(CASE WHEN o.status = 'SUCCESS' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS trial_conversion_pct,
    ROUND(AVG(o.amount), 2) AS avg_trial_amount,
    (SELECT COUNT(*) FROM order_details od
       JOIN orders o2 ON o2.id = od.order_id
      WHERE o2.plan_id = o.plan_id AND od.status = 'SUCCESS') AS subscriptions_successful
FROM orders o
WHERE o.plan_id IS NOT NULL
GROUP BY o.plan_id
ORDER BY total_orders DESC;

-- 4.4 Multiple subscription attempts (retry distribution)
SELECT
    attempt_count,
    COUNT(*) AS orders_with_this_many_attempts,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_attempted_orders
FROM (
    SELECT order_id, COUNT(*) AS attempt_count
    FROM order_details
    GROUP BY order_id
) t
GROUP BY attempt_count
ORDER BY attempt_count;

-- 4.5 Additional Insight 1: Marketing partner / channel performance
SELECT
    partner,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS trials_started,
    ROUND(SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS trial_conversion_pct
FROM orders
WHERE partner IS NOT NULL
GROUP BY partner
ORDER BY total_orders DESC
LIMIT 10;

-- 4.6 Additional Insight 2: Trial duration vs subscription conversion
SELECT
    o.trial_duration,
    COUNT(*) AS trials,
    SUM(CASE WHEN o.id IN (SELECT order_id FROM order_details WHERE status = 'SUCCESS') THEN 1 ELSE 0 END) AS converted_to_paid,
    ROUND(SUM(CASE WHEN o.id IN (SELECT order_id FROM order_details WHERE status = 'SUCCESS') THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS conversion_pct
FROM orders o
WHERE o.status = 'SUCCESS'
GROUP BY o.trial_duration
ORDER BY o.trial_duration;

-- 4.7 Additional Insight 3: Renewal depth / LTV proxy per converted subscriber
SELECT
    ROUND(AVG(success_count), 2) AS avg_successful_renewals_per_order,
    (SELECT ROUND(AVG(amount), 2) FROM order_details WHERE status = 'SUCCESS') AS avg_renewal_amount
FROM (
    SELECT order_id, COUNT(*) AS success_count
    FROM order_details
    WHERE status = 'SUCCESS'
    GROUP BY order_id
) t;

-- 4.8 Additional Insight 4: Success rate by hour of day (scheduling lever for retries)
SELECT
    HOUR(order_date) AS hour_of_day,
    COUNT(*) AS total_orders,
    ROUND(SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS success_pct
FROM orders
GROUP BY HOUR(order_date)
ORDER BY hour_of_day;

-- 4.9 Additional Insight 5: Retry effectiveness (does a 2nd/3rd renewal attempt recover revenue?)
WITH ranked_attempts AS (
    SELECT
        order_id,
        status,
        ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY created_at) AS attempt_no
    FROM order_details
),
outcome AS (
    SELECT
        order_id,
        MAX(CASE WHEN attempt_no = 1 THEN status END) AS first_attempt_status,
        MAX(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS ever_succeeded
    FROM ranked_attempts
    GROUP BY order_id
)
SELECT
    CASE
        WHEN first_attempt_status = 'SUCCESS' THEN 'Success on first try'
        WHEN first_attempt_status = 'FAILED' AND ever_succeeded = 1 THEN 'Recovered on retry'
        ELSE 'Never recovered'
    END AS retry_outcome,
    COUNT(*) AS orders,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM outcome
GROUP BY retry_outcome
ORDER BY orders DESC;
