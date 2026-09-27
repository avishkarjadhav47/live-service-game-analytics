USE ea_analyst_takehome;

-- ============================================================
-- 04_spender_behaviour.sql — Part 1(c)
-- ============================================================


-- 4A. Revenue concentration — two populations
WITH player_rev AS (
    SELECT p.device_id, COALESCE(SUM(pc.usd_amount), 0) AS gross
    FROM player_profile p
    LEFT JOIN purchase_clean pc ON pc.device_id = p.device_id AND pc.usd_amount > 0
    GROUP BY p.device_id
),
payers AS (
    SELECT gross, ROW_NUMBER() OVER (ORDER BY gross DESC, device_id) AS rk,
           COUNT(*) OVER () AS n, SUM(gross) OVER () AS total
    FROM player_rev WHERE gross > 0
),
everyone AS (
    SELECT gross, ROW_NUMBER() OVER (ORDER BY gross DESC, device_id) AS rk,
           COUNT(*) OVER () AS n, SUM(gross) OVER () AS total
    FROM player_rev
)
SELECT 'payers only' AS ranked_population, MAX(n) AS players,
       ROUND(SUM(CASE WHEN rk <= CEIL(n*0.01) THEN gross END) / MAX(total), 4) AS top_1pct_share,
       ROUND(SUM(CASE WHEN rk <= CEIL(n*0.10) THEN gross END) / MAX(total), 4) AS top_10pct_share,
       ROUND(SUM(CASE WHEN rk <= CEIL(n*0.50) THEN gross END) / MAX(total), 4) AS top_50pct_share
FROM payers
UNION ALL
SELECT 'everyone', MAX(n),
       ROUND(SUM(CASE WHEN rk <= CEIL(n*0.01) THEN gross END) / MAX(total), 4),
       ROUND(SUM(CASE WHEN rk <= CEIL(n*0.10) THEN gross END) / MAX(total), 4),
       ROUND(SUM(CASE WHEN rk <= CEIL(n*0.50) THEN gross END) / MAX(total), 4)
FROM everyone;


-- 4B. Time to first purchase
WITH first_buy AS (
    SELECT device_id, MIN(event_dt) AS first_dt
    FROM purchase_clean WHERE usd_amount > 0 GROUP BY device_id
),
base AS (
    SELECT p.device_id,
           CASE WHEN f.first_dt IS NULL THEN NULL
                ELSE GREATEST(DATEDIFF(f.first_dt, p.install_date), 0) END AS days_to_first
    FROM player_profile p
    LEFT JOIN first_buy f USING (device_id)
    WHERE p.install_date BETWEEN '2026-01-01' AND '2026-03-31'
),
bucketed AS (
    SELECT CASE WHEN days_to_first IS NULL OR days_to_first > 29 THEN 'no purchase by day 29'
                WHEN days_to_first = 0 THEN 'day 0'
                WHEN days_to_first <= 3 THEN 'days 1-3'
                WHEN days_to_first <= 7 THEN 'days 4-7'
                WHEN days_to_first <= 14 THEN 'days 8-14'
                ELSE 'days 15-29' END AS bucket,
           CASE WHEN days_to_first IS NULL OR days_to_first > 29 THEN 9
                WHEN days_to_first = 0 THEN 1
                WHEN days_to_first <= 3 THEN 2
                WHEN days_to_first <= 7 THEN 3
                WHEN days_to_first <= 14 THEN 4
                ELSE 5 END AS ord
    FROM base
)
SELECT bucket, COUNT(*) AS installs,
       ROUND(COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_of_installs
FROM bucketed
GROUP BY bucket, ord
ORDER BY ord;

-- 4B-ii. Percentiles among installs that paid within 30 days
WITH first_buy AS (
    SELECT device_id, MIN(event_dt) AS first_dt
    FROM purchase_clean WHERE usd_amount > 0 GROUP BY device_id
),
paid AS (
    SELECT GREATEST(DATEDIFF(f.first_dt, p.install_date), 0) AS d
    FROM player_profile p JOIN first_buy f USING (device_id)
    WHERE p.install_date BETWEEN '2026-01-01' AND '2026-03-31'
      AND DATEDIFF(f.first_dt, p.install_date) <= 29
),
r AS (SELECT d, ROW_NUMBER() OVER (ORDER BY d) AS rk, COUNT(*) OVER () AS n FROM paid)
SELECT MAX(n) AS payers_within_30d,
       MIN(CASE WHEN rk >= 0.25*n THEN d END) AS p25_days,
       MIN(CASE WHEN rk >= 0.50*n THEN d END) AS median_days,
       MIN(CASE WHEN rk >= 0.75*n THEN d END) AS p75_days,
       MIN(CASE WHEN rk >= 0.90*n THEN d END) AS p90_days
FROM r;

-- 4B-iii. Cumulative conversion curve (each point uses only installs that
--         have been observed for at least that many days)
WITH first_buy AS (
    SELECT device_id, MIN(event_dt) AS first_dt
    FROM purchase_clean WHERE usd_amount > 0 GROUP BY device_id
),
base AS (
    SELECT p.install_date,
           GREATEST(DATEDIFF(f.first_dt, p.install_date), 0) AS d
    FROM player_profile p LEFT JOIN first_buy f USING (device_id)
    WHERE p.install_date >= '2026-01-01'
),
horizons AS (
    SELECT 0 AS k UNION ALL SELECT 3 UNION ALL SELECT 7 UNION ALL SELECT 14
    UNION ALL SELECT 30 UNION ALL SELECT 60 UNION ALL SELECT 90
)
SELECT h.k AS by_day,
       COUNT(*) AS eligible_installs,
       ROUND(AVG(b.d IS NOT NULL AND b.d <= h.k), 4) AS share_paid
FROM horizons h
JOIN base b ON b.install_date + INTERVAL h.k DAY <= '2026-04-30'
GROUP BY h.k
ORDER BY h.k;


-- 4C. Gap between consecutive purchases (window function, no self-join)
WITH ordered AS (
    SELECT device_id, event_ts,
           LAG(event_ts) OVER (PARTITION BY device_id ORDER BY event_ts, purchase_id) AS prev_ts
    FROM purchase_clean
    WHERE usd_amount > 0
),
gaps AS (
    SELECT TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) / 1440.0 AS gap_days
    FROM ordered WHERE prev_ts IS NOT NULL
),
r AS (SELECT gap_days, ROW_NUMBER() OVER (ORDER BY gap_days) AS rk, COUNT(*) OVER () AS n FROM gaps)
SELECT MAX(n) AS repeat_purchases,
       (SELECT COUNT(DISTINCT device_id) FROM ordered WHERE prev_ts IS NOT NULL) AS repeat_buyers,
       ROUND(MIN(CASE WHEN rk >= 0.10*n THEN gap_days END), 1) AS p10_days,
       ROUND(MIN(CASE WHEN rk >= 0.25*n THEN gap_days END), 1) AS p25_days,
       ROUND(MIN(CASE WHEN rk >= 0.50*n THEN gap_days END), 1) AS median_days,
       ROUND(MIN(CASE WHEN rk >= 0.75*n THEN gap_days END), 1) AS p75_days,
       ROUND(MIN(CASE WHEN rk >= 0.90*n THEN gap_days END), 1) AS p90_days
FROM r;

-- 4C-ii. Gap distribution, whole days
WITH ordered AS (
    SELECT device_id, event_ts,
           LAG(event_ts) OVER (PARTITION BY device_id ORDER BY event_ts, purchase_id) AS prev_ts
    FROM purchase_clean WHERE usd_amount > 0
)
SELECT CASE WHEN g < 1 THEN '< 1 day'
            WHEN g < 4 THEN '1-3'
            WHEN g < 8 THEN '4-7'
            WHEN g < 14 THEN '8-13'
            WHEN g < 17 THEN '14-16 (one sale cycle)'
            WHEN g < 31 THEN '17-30'
            WHEN g < 61 THEN '31-60'
            ELSE '61+' END AS gap_bucket,
       COUNT(*) AS repeat_purchases,
       ROUND(COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share
FROM (SELECT TIMESTAMPDIFF(MINUTE, prev_ts, event_ts) / 1440.0 AS g
      FROM ordered WHERE prev_ts IS NOT NULL) x
GROUP BY gap_bucket
ORDER BY MIN(g);


/* ============================================================
   OBSERVATION

   1. Revenue is concentrated among payers, with the top 1%,
      10% and 50% of payers accounting for 9.2%, 47.6% and
      89.9% of gross revenue respectively.
   2. Across the full player base, concentration is much higher
      because most players do not make a purchase.
   3. Among Jan-Mar installs, 11.8% make a purchase within their
      first 30 days.
   4. Among players who pay within 30 days, the median first
      purchase occurs on day 9, with an IQR of 3-17 days.
   5. The share of players who have paid continues to increase
      beyond day 30, so "never pays" depends on the observation
      horizon.
   6. There are 4,024 repeat purchases from 2,476 repeat buyers;
      the median gap between purchases is 15.3 days.

   ACTION

   1. Use the payer population for spender concentration and
      monetization behaviour.
   2. Use the full player base when evaluating the value of new
      installs.
   3. Use a fixed 30-day horizon when comparing first-purchase
      conversion across install cohorts.
   4. Report repeat-purchase gaps using transaction timestamps.
   5. Treat the 15-day purchase cadence as an observed pattern,
      not proof that promotions cause repeat purchases.

   CONCLUSION

   1. Monetization is concentrated among a relatively small payer
      population.
   2. First-purchase conversion is front-loaded but continues to
      build beyond 30 days.
   3. Repeat purchasing shows a roughly two-week cadence that is
      useful for subsequent monetization analysis.
   ============================================================ */
