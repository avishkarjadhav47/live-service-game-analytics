USE ea_analyst_takehome;

-- ============================================================
-- 03_retention.sql — Part 1(b)
-- ============================================================


-- 3A. Retention grid: cohorts down, milestones across
WITH cohorts AS (
    SELECT device_id, install_date,
           DATE_SUB(install_date, INTERVAL WEEKDAY(install_date) DAY) AS install_week
    FROM player_profile
    WHERE install_date BETWEEN '2026-01-01' AND '2026-04-30'
),
flags AS (
    SELECT c.install_week, c.install_date, c.device_id,
           MAX(d.activity_dt = c.install_date + INTERVAL 1 DAY)  AS d1,
           MAX(d.activity_dt = c.install_date + INTERVAL 7 DAY)  AS d7,
           MAX(d.activity_dt = c.install_date + INTERVAL 14 DAY) AS d14,
           MAX(d.activity_dt = c.install_date + INTERVAL 30 DAY) AS d30
    FROM cohorts c
    LEFT JOIN player_day d
      ON d.device_id = c.device_id
     AND d.activity_dt IN (c.install_date + INTERVAL 1 DAY,  c.install_date + INTERVAL 7 DAY,
                           c.install_date + INTERVAL 14 DAY, c.install_date + INTERVAL 30 DAY)
    GROUP BY c.install_week, c.install_date, c.device_id
),
grid AS (
    SELECT install_week,
           COUNT(*) AS cohort_size,
           MAX(install_date) AS last_install,
           AVG(COALESCE(d1, 0))  AS d1,
           AVG(COALESCE(d7, 0))  AS d7,
           AVG(COALESCE(d14, 0)) AS d14,
           AVG(COALESCE(d30, 0)) AS d30
    FROM flags
    GROUP BY install_week
)
SELECT install_week, cohort_size,
       CASE WHEN last_install + INTERVAL 1 DAY  <= '2026-04-30' THEN ROUND(d1, 4)  END AS d1_retention,
       CASE WHEN last_install + INTERVAL 7 DAY  <= '2026-04-30' THEN ROUND(d7, 4)  END AS d7_retention,
       CASE WHEN last_install + INTERVAL 14 DAY <= '2026-04-30' THEN ROUND(d14, 4) END AS d14_retention,
       CASE WHEN last_install + INTERVAL 30 DAY <= '2026-04-30' THEN ROUND(d30, 4) END AS d30_retention
FROM grid
ORDER BY install_week;


-- 3B. Player-weighted retention over fully observable installs
WITH cohorts AS (
    SELECT device_id, install_date
    FROM player_profile
    WHERE install_date BETWEEN '2026-01-01' AND '2026-04-30'
)
SELECT 'D1' AS milestone,
       ROUND(AVG(EXISTS (SELECT 1 FROM player_day d WHERE d.device_id = c.device_id
                         AND d.activity_dt = c.install_date + INTERVAL 1 DAY)), 4) AS retention,
       COUNT(*) AS eligible_installs
FROM cohorts c WHERE c.install_date + INTERVAL 1 DAY <= '2026-04-30'
UNION ALL
SELECT 'D7',
       ROUND(AVG(EXISTS (SELECT 1 FROM player_day d WHERE d.device_id = c.device_id
                         AND d.activity_dt = c.install_date + INTERVAL 7 DAY)), 4), COUNT(*)
FROM cohorts c WHERE c.install_date + INTERVAL 7 DAY <= '2026-04-30'
UNION ALL
SELECT 'D14',
       ROUND(AVG(EXISTS (SELECT 1 FROM player_day d WHERE d.device_id = c.device_id
                         AND d.activity_dt = c.install_date + INTERVAL 14 DAY)), 4), COUNT(*)
FROM cohorts c WHERE c.install_date + INTERVAL 14 DAY <= '2026-04-30'
UNION ALL
SELECT 'D30',
       ROUND(AVG(EXISTS (SELECT 1 FROM player_day d WHERE d.device_id = c.device_id
                         AND d.activity_dt = c.install_date + INTERVAL 30 DAY)), 4), COUNT(*)
FROM cohorts c WHERE c.install_date + INTERVAL 30 DAY <= '2026-04-30';


/* ============================================================
   OBSERVATION

   1. Player-weighted retention is approximately 47% at D1,
      25% at D7, 20% at D14 and 14% at D30.
   2. Retention remains broadly stable across the fully observable
      install cohorts.
   3. Recent cohorts return NULL at milestones that are not yet
      fully observable.
   4. Some players first appear in player_day after their recorded
      install date, so D1 should be interpreted with this data-quality
      limitation in mind.

   ACTION

   1. Use only fully observable installs for each retention milestone.
   2. Keep pre-window survivors out of install-based retention.
   3. Report NULL rather than zero for incomplete cohorts.
   4. Use install_date as the retention anchor defined by the brief.

   CONCLUSION

   1. Retention is broadly stable through the analysis window.
   2. The retention series is suitable for cohort-level comparison
      and downstream business analysis.
   ============================================================ */
