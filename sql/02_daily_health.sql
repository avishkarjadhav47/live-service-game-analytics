USE ea_analyst_takehome;

-- ============================================================
-- 02_daily_health.sql — Part 1(a)
-- ===========================================================


-- 2A. Daily health by platform, plus an 'All' row per day
WITH active AS (
    SELECT d.activity_dt AS dt, p.platform, d.device_id
    FROM player_day d
    JOIN player_profile p USING (device_id)
),
buyers AS (                     
    SELECT event_dt AS dt, device_id, SUM(usd_amount) AS usd
    FROM purchase_clean
    WHERE usd_amount > 0
    GROUP BY event_dt, device_id
),
revenue AS (                    
    SELECT b.dt, p.platform, SUM(b.usd) AS gross_revenue
    FROM buyers b JOIN player_profile p USING (device_id)
    GROUP BY b.dt, p.platform
),
by_platform AS (
    SELECT a.dt, a.platform,
           COUNT(*) AS dau,
           SUM(b.device_id IS NOT NULL) AS active_payers   
    FROM active a
    LEFT JOIN buyers b ON b.dt = a.dt AND b.device_id = a.device_id
    GROUP BY a.dt, a.platform
),
combined AS (
    SELECT bp.dt, bp.platform, bp.dau, COALESCE(r.gross_revenue, 0) AS gross_revenue, bp.active_payers
    FROM by_platform bp
    LEFT JOIN revenue r ON r.dt = bp.dt AND r.platform = bp.platform
),
all_platforms AS (
    SELECT dt, 'All' AS platform, SUM(dau) AS dau,
           SUM(gross_revenue) AS gross_revenue, SUM(active_payers) AS active_payers
    FROM combined
    GROUP BY dt
)
SELECT dt AS date, platform, dau, gross_revenue,
       ROUND(gross_revenue / dau, 4)  AS arpdau,
       active_payers,
       ROUND(active_payers / dau, 4)  AS payer_share
FROM (SELECT * FROM combined UNION ALL SELECT * FROM all_platforms) x
ORDER BY dt, FIELD(platform, 'All', 'Android', 'iOS');


-- 2B. Reconciliation: daily totals must add back to table totals
SELECT
    (SELECT SUM(usd_amount) FROM purchase_clean WHERE usd_amount > 0)             AS gross_total_table,
    (SELECT SUM(usd_amount) FROM purchase_clean
       JOIN player_profile USING (device_id) WHERE usd_amount > 0)                  AS gross_total_joined,
    (SELECT SUM(usd_amount) FROM purchase_clean WHERE usd_amount < 0)             AS refunds_total,
    (SELECT SUM(usd_amount) FROM purchase_clean)                                   AS net_total,
    (SELECT SUM(usd_amount) FROM purchase)                                         AS raw_table_total,
    (SELECT COUNT(*) FROM player_day)                                              AS player_days_table;



-- 2C. Period summary by platform (the numbers quoted in the deck)
SELECT a.platform, a.player_days,
       ROUND(r.gross, 2) AS gross_revenue,
       ROUND(r.gross / a.player_days, 4) AS arpdau
FROM (SELECT p.platform, COUNT(*) AS player_days
      FROM player_day d JOIN player_profile p USING (device_id) GROUP BY p.platform) a
JOIN (SELECT p.platform, SUM(pc.usd_amount) AS gross
      FROM purchase_clean pc JOIN player_profile p USING (device_id)
      WHERE pc.usd_amount > 0 GROUP BY p.platform) r USING (platform);


-- 2D. Sanity: all 120 days present; every player-day joins to a profile
SELECT COUNT(DISTINCT activity_dt) AS days_covered,
       COUNT(*) AS player_days,
       SUM(p.device_id IS NOT NULL) AS player_days_with_profile
FROM player_day d
LEFT JOIN player_profile p USING (device_id);



/* ============================================================
   OBSERVATION

   1. DAU increases substantially over the analysis window.
   2. Revenue and payer share can be measured consistently at
      the daily platform level.
   3. Gross purchase revenue is $217,593.22; refunds total
      -$3,249.74, giving net revenue of $214,343.48.
   4. Daily revenue reconciles to the cleaned purchase table.
   5. The extract contains all 120 analysis days and every
      player-day has a matching player profile.

   ACTION

   1. Use player-days as the denominator for multi-day ARPDAU.
   2. Report gross purchase revenue separately from refunds.
   3. Use active buyers for daily payer share.
   4. Retain revenue from purchases even when the buyer has
      no player_day record on the transaction date.

   CONCLUSION

   1. Daily health metrics are internally reconciled and suitable
      for downstream retention and monetization analysis.
   2. Platform-level metrics provide the base for separating
      platform performance from player-mix effects.
   ============================================================ */
