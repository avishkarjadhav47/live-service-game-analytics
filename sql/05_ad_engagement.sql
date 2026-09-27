USE ea_analyst_takehome;

-- ============================================================
-- 05_ad_engagement.sql — Part 1(d)
-- ============================================================


-- 5A. Share of ad-watching player-days that hit the cap, by cap value
WITH pdc AS (
    SELECT device_id, event_dt,
           MAX(ad_daily_cap)       AS cap,
           MAX(ad_daily_count)     AS max_count,
           COUNT(*)                AS interactions,
           SUM(status = 'completed') AS completed
    FROM ad_view_local
    WHERE event_dt BETWEEN '2026-01-01' AND '2026-04-30'
    GROUP BY device_id, event_dt
)
SELECT cap,
       COUNT(*)                            AS ad_player_days,
       SUM(max_count >= cap)               AS hit_cap_days,
       ROUND(AVG(max_count >= cap), 4)     AS hit_cap_share,
       ROUND(AVG(completed >= cap), 4)     AS hit_cap_share_completed_only,
       ROUND(AVG(interactions), 3)         AS avg_interactions_per_day,
       ROUND(AVG(interactions >= 5), 4)    AS share_with_5plus
FROM pdc
GROUP BY cap
ORDER BY cap;

-- 5A-ii. Checks behind 5A
SELECT
    (SELECT COUNT(*) FROM (SELECT device_id, event_dt FROM ad_view_local
        GROUP BY device_id, event_dt HAVING COUNT(DISTINCT ad_daily_cap) > 1) x) AS days_with_two_caps,
    (SELECT SUM(mx = n) / COUNT(*) FROM (SELECT MAX(ad_daily_count) mx, COUNT(*) n FROM ad_view_local
        GROUP BY device_id, event_dt) y) AS share_days_counter_equals_rows,
    (SELECT COUNT(*) FROM (SELECT device_id FROM (SELECT DISTINCT device_id, ad_daily_cap FROM ad_view_local) z
        GROUP BY device_id HAVING COUNT(*) > 1) w) AS players_seen_with_both_caps;


-- 5B. Daily ad volume (plot this). Missing days are listed explicitly.
WITH RECURSIVE days AS (
    SELECT DATE('2026-01-01') AS dt
    UNION ALL SELECT dt + INTERVAL 1 DAY FROM days WHERE dt < '2026-04-30'
),
ads AS (
    SELECT event_dt AS dt, COUNT(*) AS interactions,
           SUM(status = 'completed') AS completed_views,
           COUNT(DISTINCT device_id) AS ad_players
    FROM ad_view_local GROUP BY event_dt
),
dau AS (SELECT activity_dt AS dt, COUNT(*) AS dau FROM player_day GROUP BY activity_dt)
SELECT d.dt AS date,
       dau.dau,
       ads.interactions,
       ads.completed_views,
       ROUND(ads.completed_views / ads.interactions, 4) AS completion_rate,
       ROUND(ads.completed_views / dau.dau, 3)          AS completed_views_per_dau,
       ROUND(ads.ad_players / dau.dau, 3)               AS share_of_dau_watching,
       CASE WHEN ads.dt IS NULL THEN 'NO AD DATA' END   AS flag
FROM days d
LEFT JOIN ads USING (dt)
LEFT JOIN dau USING (dt)
ORDER BY d.dt;


-- 5C. Placement-level engagement
SELECT placement,
       COUNT(*) AS interactions,
       COUNT(DISTINCT device_id) AS players,
       ROUND(AVG(status = 'completed'), 4) AS completion_rate
FROM ad_view_local
GROUP BY placement
ORDER BY interactions DESC;


-- 5D. Ad engagement per active player: early vs late window (excl. outage)
SELECT CASE WHEN a.dt < '2026-02-01' THEN 'Jan' WHEN a.dt >= '2026-04-01' THEN 'Apr' END AS period,
       ROUND(SUM(a.completed) / SUM(d.dau), 3) AS completed_views_per_dau
FROM (SELECT event_dt AS dt, SUM(status='completed') AS completed FROM ad_view_local GROUP BY event_dt) a
JOIN (SELECT activity_dt AS dt, COUNT(*) AS dau FROM player_day GROUP BY activity_dt) d USING (dt)
WHERE a.dt < '2026-02-01' OR a.dt >= '2026-04-01'
GROUP BY period;


/* ============================================================
   OBSERVATION

   1. Only 1.27% of cap-5 player-days reach the cap and about
      0.02% of cap-8 player-days reach the cap.
   2. Average ad interactions are 1.65 per player-day for both
      cap levels, with 1.27% of days reaching 5+ interactions.
   3. Completed views per DAU increase from 0.75 in January to
      0.85 in April.
   4. Ad telemetry is missing on 2026-03-05 and 2026-03-06 while
      the other activity tables continue to report data.
   5. Placement completion rates are broadly similar.
   6. The corrected local-time analysis removes the apparent
      May 1 spillover and within-day cap changes seen in raw time.

   ACTION

   1. Do not treat the cap as the primary engagement constraint
      based on the observed data.
   2. Confirm how cap values are assigned before comparing cap
      levels as an experiment.
   3. Exclude the two ad-telemetry outage days from ad trend
      comparisons rather than treating them as zero engagement.
   4. Use placement-level completion and volume as monitoring
      metrics rather than making a placement change from these
      results alone.
   5. Treat reward_amount as an in-game economy cost, not revenue.

   CONCLUSION

   1. Observed ad engagement is well below the configured caps,
      so the current telemetry does not show the cap as a binding
      constraint on typical ad usage.
   2. Completed ad views per DAU increase from January to April, indicating higher ad engagement per active player,
      with a discrete telemetry gap in early March.
   3. Any cap or placement change should be validated with
      assignment information or an experiment.
   ============================================================ */
