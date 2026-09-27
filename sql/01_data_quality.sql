USE ea_analyst_takehome;

-- ============================================================
-- 01_data_quality.sql
-- Grain, coverage and anomaly checks. Each block ends with what
-- was found and how it is handled downstream. Summary at the end.
-- ============================================================


-- 1A. Row counts and grain
SELECT 'player_profile' AS table_name, COUNT(*) AS n_rows, COUNT(DISTINCT device_id) AS n_keys FROM player_profile
UNION ALL
SELECT 'player_day', COUNT(*), COUNT(DISTINCT device_id, activity_date) FROM player_day
UNION ALL
SELECT 'purchase', COUNT(*), COUNT(DISTINCT purchase_id) FROM purchase;



-- 1B. Join integrity: every event device exists in player_profile
SELECT 'player_day' AS table_name, COUNT(DISTINCT e.device_id) AS unmatched_devices
FROM player_day e LEFT JOIN player_profile p USING (device_id) WHERE p.device_id IS NULL
UNION ALL
SELECT 'purchase', COUNT(DISTINCT e.device_id)
FROM purchase e LEFT JOIN player_profile p USING (device_id) WHERE p.device_id IS NULL
UNION ALL
SELECT 'currency_spend', COUNT(DISTINCT e.device_id)
FROM currency_spend e LEFT JOIN player_profile p USING (device_id) WHERE p.device_id IS NULL
UNION ALL
SELECT 'ad_view', COUNT(DISTINCT e.device_id)
FROM ad_view e LEFT JOIN player_profile p USING (device_id) WHERE p.device_id IS NULL;
-- All 0.


-- 1C. Who is in the extract: pre-window installs are survivors
SELECT
    CASE WHEN p.install_date < '2026-01-01' THEN 'installed before window' ELSE 'installed in window' END AS grp,
    COUNT(*) AS players,
    MIN(p.install_date) AS first_install,
    MAX(p.install_date) AS last_install,
    ROUND(AVG(a.device_id IS NOT NULL), 4) AS share_active_in_window
FROM player_profile p
LEFT JOIN (SELECT DISTINCT device_id FROM player_day) a USING (device_id)
GROUP BY grp;



-- 1D. Duplicate purchase_ids
SELECT
    COUNT(*) AS duplicated_ids,
    SUM(n_rows - 1) AS extra_rows,
    SUM(extra_usd) AS extra_usd,
    SUM(same_fields) AS ids_with_identical_fields,
    SUM(same_day) AS ids_logged_same_day
FROM (
    SELECT purchase_id,
           COUNT(*) AS n_rows,
           SUM(usd_amount) - MIN(usd_amount) AS extra_usd,
           (COUNT(DISTINCT device_id, pack_name, usd_amount) = 1) AS same_fields,
           (COUNT(DISTINCT DATE(event_ts)) = 1) AS same_day
    FROM purchase
    GROUP BY purchase_id
    HAVING COUNT(*) > 1
) d;



-- 1E. Negative purchases (refunds)
SELECT
    COUNT(*) AS refund_rows,
    SUM(usd_amount) AS refund_usd,
    SUM(EXISTS (SELECT 1 FROM purchase_clean o
                WHERE o.device_id = r.device_id AND o.pack_name = r.pack_name
                  AND o.usd_amount = -r.usd_amount AND o.event_ts < r.event_ts)) AS matched_to_earlier_purchase
FROM purchase_clean r
WHERE usd_amount < 0;



-- 1F. Purchases before the recorded install date
SELECT COUNT(*) AS purchases_before_install, COUNT(DISTINCT pc.device_id) AS players
FROM purchase_clean pc JOIN player_profile p USING (device_id)
WHERE pc.event_dt < p.install_date AND pc.usd_amount > 0;



-- 1G. Timestamp ranges by table (the ad_view clock is different)
SELECT 'purchase' AS table_name, MIN(HOUR(event_ts)) AS min_hour, MAX(HOUR(event_ts)) AS max_hour FROM purchase
UNION ALL
SELECT 'currency_spend', MIN(HOUR(event_ts)), MAX(HOUR(event_ts)) FROM currency_spend
UNION ALL
SELECT 'ad_view (raw)',  MIN(HOUR(event_ts)), MAX(HOUR(event_ts)) FROM ad_view;

SELECT HOUR(event_ts) AS hour_raw, COUNT(*) AS ad_events
FROM ad_view GROUP BY HOUR(event_ts) ORDER BY hour_raw;



-- 1H. Test the +8h hypothesis: do ad days line up with active days?
SELECT
    'raw ad timestamps' AS version,
    COUNT(*) AS ad_player_days,
    SUM(NOT EXISTS (SELECT 1 FROM player_day d
                    WHERE d.device_id = a.device_id AND d.activity_dt = a.dt)) AS no_matching_active_day
FROM (SELECT DISTINCT device_id, DATE(event_ts) AS dt FROM ad_view) a
UNION ALL
SELECT
    'shifted -8h',
    COUNT(*),
    SUM(NOT EXISTS (SELECT 1 FROM player_day d
                    WHERE d.device_id = a.device_id AND d.activity_dt = a.dt))
FROM (SELECT DISTINCT device_id, event_dt AS dt FROM ad_view_local) a;


SELECT 'raw day boundary' AS version, COUNT(*) AS player_days_with_2_caps
FROM (SELECT device_id, DATE(event_ts) FROM ad_view
      GROUP BY device_id, DATE(event_ts) HAVING COUNT(DISTINCT ad_daily_cap) > 1) x
UNION ALL
SELECT 'local day boundary', COUNT(*)
FROM (SELECT device_id, event_dt FROM ad_view_local
      GROUP BY device_id, event_dt HAVING COUNT(DISTINCT ad_daily_cap) > 1) x;



-- 1I. Daily coverage across tables (gaps)
WITH RECURSIVE days AS (
    SELECT DATE('2026-01-01') AS dt
    UNION ALL SELECT dt + INTERVAL 1 DAY FROM days WHERE dt < '2026-04-30'
)
SELECT d.dt,
       (SELECT COUNT(*) FROM player_day     x WHERE x.activity_dt = d.dt) AS active_rows,
       (SELECT COUNT(*) FROM purchase_clean x WHERE x.event_dt = d.dt)    AS purchases,
       (SELECT COUNT(*) FROM ad_view_local  x WHERE x.event_dt = d.dt)    AS ad_events
FROM days d
HAVING active_rows = 0 OR purchases = 0 OR ad_events = 0;



-- 1J. Purchases on days with no player_day row
SELECT
    COUNT(*) AS gross_purchases,
    SUM(NOT EXISTS (SELECT 1 FROM player_day d
                    WHERE d.device_id = pc.device_id AND d.activity_dt = pc.event_dt)) AS no_active_row,
    ROUND(SUM(CASE WHEN NOT EXISTS (SELECT 1 FROM player_day d
                    WHERE d.device_id = pc.device_id AND d.activity_dt = pc.event_dt)
              THEN usd_amount ELSE 0 END), 2) AS usd_no_active_row
FROM purchase_clean pc
WHERE usd_amount > 0;



-- 1K. original_device_id: are the links credible?
SELECT
    COUNT(*) AS linked_players,
    SUM(p.original_device_id = p.device_id) AS linked_to_self,
    SUM(p.country  <> o.country)  AS different_country,
    SUM(p.platform <> o.platform) AS different_platform,
    SUM(p.install_date < o.install_date) AS installed_before_original
FROM player_profile p
JOIN player_profile o ON o.device_id = p.original_device_id;



-- 1L. Currency spend outliers
SELECT
    COUNT(*) AS spend_events_over_50k,
    COUNT(DISTINCT device_id) AS devices,
    MAX(currency_value) AS max_value
FROM currency_spend
WHERE currency_value > 50000;

SELECT currency_type, ROUND(AVG(currency_value)) AS mean_value,
       MAX(CASE WHEN currency_type='PREMIUM' THEN premium_balance
                WHEN currency_type='SOCIAL'  THEN social_balance
                ELSE grind_balance END) AS max_balance_seen
FROM currency_spend WHERE currency_value <= 50000 GROUP BY currency_type;



-- 1M. Install volume and mix by week (why pooling across weeks misleads)
SELECT
    DATE_SUB(install_date, INTERVAL WEEKDAY(install_date) DAY) AS install_week,
    COUNT(*) AS installs,
    ROUND(AVG(acquisition_channel = 'organic'), 3) AS organic_share,
    ROUND(AVG(acquisition_channel = 'paid_video'), 3) AS paid_video_share,
    ROUND(AVG(country_tier = 4), 3) AS tier4_share
FROM player_profile
WHERE install_date >= '2026-01-01'
GROUP BY install_week
ORDER BY install_week;



-- 1N. Install date vs first activity
SELECT DATEDIFF(f.first_active, p.install_date) AS days_install_to_first_activity,
       COUNT(*) AS players
FROM player_profile p
JOIN (SELECT device_id, MIN(activity_dt) AS first_active FROM player_day GROUP BY device_id) f
  USING (device_id)
WHERE p.install_date >= '2026-01-01'
GROUP BY days_install_to_first_activity
ORDER BY days_install_to_first_activity
LIMIT 8;


/* ============================================================
   OBSERVATION
   1. 122 purchase_ids are duplicated.
   2. ad_view timestamps show a consistent 8-hour offset.
   3. 16,000 players were installed before the analysis window.
   4. Refund transactions are present.
   5. Some purchases have no matching player_day record.
   6. original_device_id links are unreliable.
   7. A small set of currency-spend records are highly anomalous.
   8. Install volume and player mix change substantially over time.
   9. Two days have missing ad telemetry after timestamp correction.
   10. Some players first appear in player_day after their install date.

   ACTION
   1. Deduplicate purchase_ids in purchase_clean.
   2. Shift ad timestamps by 8 hours in ad_view_local.
   3. Exclude pre-window players from install-based metrics.
   4. Keep refunds separately from positive purchase revenue.
   5. Retain purchases using their transaction date.
   6. Do not merge players using original_device_id.
   7. Exclude anomalous economy records from economy analysis.
   8. Use cohort/mix-aware comparisons for acquisition analysis.
   9. Exclude the ad-telemetry gap from ad trend analysis.
   10. Retain install_date as the retention anchor.

   CONCLUSION
   1. The cleaned tables are suitable for the downstream analysis.
   2. The main data-quality risks are explicitly handled rather than
      silently dropped.
   ============================================================ */
