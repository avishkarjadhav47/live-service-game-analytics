
-- setup.sql


CREATE DATABASE IF NOT EXISTS ea_analyst_takehome;
USE ea_analyst_takehome;

DROP TABLE IF EXISTS ad_view_local;
DROP TABLE IF EXISTS purchase_clean;
DROP TABLE IF EXISTS ad_view;
DROP TABLE IF EXISTS currency_spend;
DROP TABLE IF EXISTS purchase;
DROP TABLE IF EXISTS player_day;
DROP TABLE IF EXISTS player_profile;

-- ------------------------------------------------------------
-- 1. player_profile  (grain: one row per player)
-- ------------------------------------------------------------
CREATE TABLE player_profile (
    device_id            INT PRIMARY KEY,
    original_device_id   INT NULL,
    install_date         DATE,
    platform             VARCHAR(20),
    country              VARCHAR(50),
    country_tier         INT,
    acquisition_channel  VARCHAR(30),
    first_purchase_date  DATE NULL
);

LOAD DATA LOCAL INFILE 'C:/Placement/EA-Analyst-Take-Home/data/player_profile.csv'
INTO TABLE player_profile
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(device_id, @original_device_id, install_date, platform, country,
 country_tier, acquisition_channel, @first_purchase_date)
SET original_device_id  = NULLIF(@original_device_id, ''),
    first_purchase_date = NULLIF(TRIM(TRAILING '\r' FROM @first_purchase_date), '');

-- ------------------------------------------------------------
-- 2. player_day  (grain: one row per player per active day)
-- ------------------------------------------------------------
CREATE TABLE player_day (
    device_id         INT,
    activity_date     INT,           -- YYYYMMDD as supplied
    activity_dt       DATE,          -- same value as a real DATE
    player_level      INT,
    session_count     INT,
    playtime_minutes  DOUBLE,
    app_version       VARCHAR(20)
);

LOAD DATA LOCAL INFILE 'C:/Placement/EA-Analyst-Take-Home/data/player_day.csv'
INTO TABLE player_day
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(device_id, activity_date, player_level, session_count, playtime_minutes, @app_version)
SET app_version = TRIM(TRAILING '\r' FROM @app_version),
    activity_dt = STR_TO_DATE(CAST(activity_date AS CHAR), '%Y%m%d');

-- ------------------------------------------------------------
-- 3. purchase  (grain: one row per real-money transaction)
-- ------------------------------------------------------------
CREATE TABLE purchase (
    purchase_id       VARCHAR(20),
    device_id         INT,
    event_ts          DATETIME,
    pack_name         VARCHAR(50),
    usd_amount        DECIMAL(10,2),
    currency_granted  INT,
    sale_flag         TINYINT
);

LOAD DATA LOCAL INFILE 'C:/Placement/EA-Analyst-Take-Home/data/purchase.csv'
INTO TABLE purchase
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(purchase_id, device_id, event_ts, pack_name, usd_amount, currency_granted, @sale_flag)
SET sale_flag = TRIM(TRAILING '\r' FROM @sale_flag);

-- ------------------------------------------------------------
-- 4. currency_spend  (grain: one row per in-game spend event)
-- ------------------------------------------------------------
CREATE TABLE currency_spend (
    device_id        INT,
    event_ts         DATETIME,
    spend_type       VARCHAR(20),
    currency_type    VARCHAR(20),
    currency_value   BIGINT,
    spend_category   VARCHAR(50),
    player_level     INT,
    premium_balance  INT,
    social_balance   INT,
    grind_balance    INT
);

LOAD DATA LOCAL INFILE 'C:/Placement/EA-Analyst-Take-Home/data/currency_spend.csv'
INTO TABLE currency_spend
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(device_id, event_ts, spend_type, currency_type, currency_value, spend_category,
 player_level, premium_balance, social_balance, @grind_balance)
SET grind_balance = TRIM(TRAILING '\r' FROM @grind_balance);

-- ------------------------------------------------------------
-- 5. ad_view  (grain: one row per rewarded-ad interaction)
-- ------------------------------------------------------------
CREATE TABLE ad_view (
    device_id       INT,
    event_ts        DATETIME,
    status          VARCHAR(20),
    placement       VARCHAR(50),
    reward_type     VARCHAR(30),
    reward_amount   INT,
    ad_daily_count  INT,
    ad_daily_cap    INT
);

LOAD DATA LOCAL INFILE 'C:/Placement/EA-Analyst-Take-Home/data/ad_view.csv'
INTO TABLE ad_view
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(device_id, event_ts, status, placement, reward_type, reward_amount, ad_daily_count, @ad_daily_cap)
SET ad_daily_cap = TRIM(TRAILING '\r' FROM @ad_daily_cap);

-- ------------------------------------------------------------
-- 6. Indexes
-- ------------------------------------------------------------
CREATE INDEX idx_pd_player_dt   ON player_day (device_id, activity_dt);
CREATE INDEX idx_pd_dt          ON player_day (activity_dt);
CREATE INDEX idx_pur_player_ts  ON purchase (device_id, event_ts);
CREATE INDEX idx_pur_id         ON purchase (purchase_id);
CREATE INDEX idx_cs_player_ts   ON currency_spend (device_id, event_ts);
CREATE INDEX idx_ad_player_ts   ON ad_view (device_id, event_ts);

-- ------------------------------------------------------------
-- 7. Cleaned tables (justification in 01_data_quality.sql)
-- ------------------------------------------------------------

-- 7a. purchase_clean
--   * 122 purchase_ids appear twice: identical device, pack and amount,
--     logged hours apart on the same day -> duplicate logging. Keep the
--     first occurrence.
--   * Negative rows (228, refunds) are KEPT here, flagged by is_refund.
--     Gross revenue = positive rows only; net = gross + refunds.
CREATE TABLE purchase_clean AS
SELECT purchase_id, device_id, event_ts, DATE(event_ts) AS event_dt,
       pack_name, usd_amount, currency_granted, sale_flag,
       (usd_amount < 0) AS is_refund
FROM (
    SELECT p.*,
           ROW_NUMBER() OVER (PARTITION BY purchase_id ORDER BY event_ts) AS rn
    FROM purchase p
) x
WHERE rn = 1;

CREATE INDEX idx_pc_player_dt ON purchase_clean (device_id, event_dt);
CREATE INDEX idx_pc_dt        ON purchase_clean (event_dt);

-- 7b. ad_view_local
--   ad_view.event_ts is 8 hours ahead of every other table (it spans
--   14:00-07:59 while the others span 06:00-23:59). Shifting it back
--   8 hours makes every ad player-day match a player_day row (0
--   unmatched vs 51% unshifted) and removes all apparent intra-day
--   cap changes. See 01_data_quality.sql, check 1H.
CREATE TABLE ad_view_local AS
SELECT device_id,
       event_ts                               AS event_ts_raw,
       event_ts - INTERVAL 8 HOUR             AS event_ts_local,
       DATE(event_ts - INTERVAL 8 HOUR)       AS event_dt,
       status, placement, reward_type, reward_amount,
       ad_daily_count, ad_daily_cap
FROM ad_view;

CREATE INDEX idx_adl_player_dt ON ad_view_local (device_id, event_dt);
CREATE INDEX idx_adl_dt        ON ad_view_local (event_dt);

-- ------------------------------------------------------------
-- 8. Verify
-- ------------------------------------------------------------
SELECT 'player_profile' AS table_name, COUNT(*) AS row_count FROM player_profile
UNION ALL SELECT 'player_day',     COUNT(*) FROM player_day
UNION ALL SELECT 'purchase',       COUNT(*) FROM purchase
UNION ALL SELECT 'purchase_clean', COUNT(*) FROM purchase_clean
UNION ALL SELECT 'currency_spend', COUNT(*) FROM currency_spend
UNION ALL SELECT 'ad_view',        COUNT(*) FROM ad_view
UNION ALL SELECT 'ad_view_local',  COUNT(*) FROM ad_view_local;
