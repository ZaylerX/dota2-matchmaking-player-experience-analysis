/* ============================================================
   PROJECT: Dota 2 Matchmaking & Player Experience Analysis
   DATASET: Ranked Matches - November 2015 (OpenDota API)
   GOAL: Evaluate match imbalance and short-term player behavior
   ============================================================ */

-- ============================================================
-- PHASE 0 — DATABASE SETUP & BASIC TRANSFORMATIONS
-- ============================================================

CREATE DATABASE IF NOT EXISTS dota2;
USE dota2;

-- Convert radiant_win from string to boolean flag for easier analysis

ALTER TABLE dota2.`match`
ADD COLUMN radiant_win_flag TINYINT;

UPDATE dota2.`match`
SET radiant_win_flag =
    CASE
        WHEN radiant_win = 'True' THEN 1
        WHEN radiant_win = 'False' THEN 0
        ELSE NULL
    END;

-- ============================================================
-- PHASE 1 — DATA QUALITY & INTEGRITY CHECKS
-- ============================================================

-- Check record counts

SELECT COUNT(*) FROM dota2.players;
SELECT COUNT(*) FROM dota2.`match`;
SELECT COUNT(*) FROM dota2.hero_names;

-- Sample inspection

SELECT * FROM dota2.`match` LIMIT 3;

-- ------------------------------------------------------------
-- 1. Each match must have exactly 10 players
-- ------------------------------------------------------------

SELECT 
    match_id,
    COUNT(*) AS player_count
FROM dota2.players
GROUP BY match_id
HAVING COUNT(*) <> 10;

-- Expected result: 0 rows


-- ------------------------------------------------------------
-- 2. No orphan players (players without match)
-- ------------------------------------------------------------

SELECT COUNT(*) AS orphan_players
FROM dota2.players p
LEFT JOIN dota2.`match` m 
    ON p.match_id = m.match_id
WHERE m.match_id IS NULL;

-- Expected result: 0


-- ------------------------------------------------------------
-- 3. No matches without players
-- ------------------------------------------------------------

SELECT COUNT(*) AS matches_without_players
FROM dota2.`match` m
LEFT JOIN dota2.players p 
    ON m.match_id = p.match_id
WHERE p.match_id IS NULL;

-- Expected result: 0


-- ------------------------------------------------------------
-- 4. Team structure validation (5 Radiant / 5 Dire)
-- ------------------------------------------------------------

SELECT 
    match_id,
    SUM(CASE WHEN player_slot < 128 THEN 1 ELSE 0 END) AS radiant_players,
    SUM(CASE WHEN player_slot >= 128 THEN 1 ELSE 0 END) AS dire_players
FROM dota2.players
GROUP BY match_id
HAVING radiant_players <> 5 OR dire_players <> 5;

-- Expected result: 0 rows


-- ------------------------------------------------------------
-- 5. Player-level win/loss coherence check
-- ------------------------------------------------------------

SELECT 
    p.match_id,
    p.player_slot,
    CASE 
        WHEN p.player_slot < 128 AND m.radiant_win_flag = 1 THEN 1
        WHEN p.player_slot >= 128 AND m.radiant_win_flag = 0 THEN 1
        ELSE 0
    END AS player_win
FROM dota2.players p
JOIN dota2.`match` m 
    ON p.match_id = m.match_id
LIMIT 20;

-- Manual check: players on winning team flagged correctly


-- ------------------------------------------------------------
-- 6. Range checks for performance metrics
-- ------------------------------------------------------------

SELECT 
    MIN(gold_per_min) AS min_gpm,
    MAX(gold_per_min) AS max_gpm,
    MIN(xp_per_min) AS min_xpm,
    MAX(xp_per_min) AS max_xpm
FROM dota2.players;

-- Values within realistic Dota 2 ranges


-- ============================================================
-- PHASE 2 — TEAM PERFORMANCE & MATCH BALANCE PROXY
-- ============================================================

-- ------------------------------------------------------------
-- Create team-level aggregated view
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW match_team_stats AS
SELECT
    p.match_id,
    CASE 
        WHEN p.player_slot < 128 THEN 'Radiant'
        ELSE 'Dire'
    END AS team,

    MAX(CASE
        WHEN (p.player_slot < 128 AND m.radiant_win_flag = 1) 
          OR (p.player_slot >= 128 AND m.radiant_win_flag = 0)
        THEN 1 ELSE 0
    END) AS win_flag,

    AVG(p.gold_per_min) AS avg_team_gpm,
    AVG(p.xp_per_min) AS avg_team_xpm,
    SUM(p.kills) AS total_team_kills,
    SUM(p.assists) AS total_team_assists,
    SUM(p.deaths) AS total_team_deaths,

    -- Post-match performance proxy (NOT true pre-match skill)
    AVG(p.gold_per_min) + AVG(p.xp_per_min) AS team_skill_proxy

FROM dota2.players p
JOIN dota2.`match` m 
    ON p.match_id = m.match_id
GROUP BY p.match_id, team;


-- Integrity check: 2 rows per match

SELECT COUNT(*) FROM dota2.match_team_stats;

SELECT match_id
FROM dota2.match_team_stats
GROUP BY match_id
HAVING SUM(win_flag) <> 1;

-- Expected result: 0 rows


-- ------------------------------------------------------------
-- Create match-level fairness proxy
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW match_fairness AS 
SELECT 
    r.match_id,

    CASE WHEN r.win_flag = 1 THEN 1 ELSE 0 END AS radiant_win,

    r.team_skill_proxy AS radiant_skill,
    d.team_skill_proxy AS dire_skill,

    (r.team_skill_proxy - d.team_skill_proxy) AS skill_diff,
    ABS(r.team_skill_proxy - d.team_skill_proxy) AS skill_gap

FROM match_team_stats r
JOIN match_team_stats d
    ON r.match_id = d.match_id
WHERE r.team = 'Radiant' AND d.team = 'Dire';


SELECT COUNT(*) FROM match_fairness;

-- Expected: one row per match


-- ------------------------------------------------------------
-- Validate proxy via favorite win rate (sanity check)
-- ------------------------------------------------------------

SELECT
    CASE 
        WHEN skill_gap <= 50 THEN 'Very Fair'
        WHEN skill_gap <= 150 THEN 'Fair'
        WHEN skill_gap <= 300 THEN 'Unbalanced'
        ELSE 'Stomp'
    END AS gap_bucket,

    COUNT(*) AS match_count,

    AVG(CASE 
        WHEN skill_diff > 0 AND radiant_win = 1 THEN 1
        WHEN skill_diff < 0 AND radiant_win = 0 THEN 1
        ELSE 0
    END) AS favorite_win_rate

FROM match_fairness
GROUP BY gap_bucket;

-- Result shows near-perfect alignment between proxy and outcome.
-- Conclusion: proxy is endogeneous and reflects outcome itself.
-- Therefore: NOT usable for matchmaking fairness evaluation,
-- but still usable to describe experienced match imbalance.


-- ============================================================
-- PHASE 3 — STOMP MATCH IDENTIFICATION
-- ============================================================

-- ------------------------------------------------------------
-- Compute median match duration
-- ------------------------------------------------------------

WITH t1 AS (
    SELECT 
        duration,
        ROW_NUMBER() OVER (ORDER BY duration) AS rn,
        COUNT(*) OVER () AS total_rows
    FROM dota2.`match`
)
SELECT AVG(duration) AS median_duration
FROM t1
WHERE rn IN (
    FLOOR((total_rows + 1)/2),
    FLOOR((total_rows + 2)/2)
);

-- Median duration ≈ 2415 seconds


-- ------------------------------------------------------------
-- Define stomp: large skill gap + short duration
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW match_stomp_stats AS
SELECT 
    mf.match_id,
    mf.skill_gap,
    m.duration,

    CASE
        WHEN mf.skill_gap > 300 AND m.duration < 2415 THEN 1
        ELSE 0
    END AS stomp_flag

FROM match_fairness mf
JOIN dota2.`match` m
    ON mf.match_id = m.match_id;


-- Validate stomp rate

SELECT 
    SUM(stomp_flag) AS stomp_matches,
    COUNT(*) AS total_matches,
    AVG(stomp_flag) AS stomp_rate
FROM match_stomp_stats;

-- Overall stomp rate ≈ 28.75%


-- ------------------------------------------------------------
-- Stomp rate by skill tier
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW stomp_rate_per_tier AS
WITH t1 AS (
    SELECT
        mss.match_id,
        mss.stomp_flag,
        (mf.radiant_skill + mf.dire_skill) / 2 AS match_avg_skill,

        NTILE(3) OVER (
            ORDER BY (mf.radiant_skill + mf.dire_skill) / 2
        ) AS skill_tier_num

    FROM match_stomp_stats mss
    JOIN match_fairness mf
        ON mss.match_id = mf.match_id
)

SELECT 
    CASE 
        WHEN skill_tier_num = 1 THEN 'Low'
        WHEN skill_tier_num = 2 THEN 'Mid'
        WHEN skill_tier_num = 3 THEN 'High'
    END AS skill_tier,

    COUNT(*) AS total_matches,
    SUM(stomp_flag) AS stomp_matches,
    AVG(stomp_flag) AS stomp_rate

FROM t1
GROUP BY skill_tier;


-- ============================================================
-- PHASE 4 — SESSION-LEVEL PLAYER CONTINUATION (NOT TRUE CHURN)
-- ============================================================

-- IMPORTANT:
-- This measures whether players queue another match within the
-- observation window, NOT long-term churn or retention.


-- ------------------------------------------------------------
-- Player event stream with next match timestamp
-- ------------------------------------------------------------

WITH player_events AS (
    SELECT
        p.account_id,
        m.match_id,
        m.start_time,

        mss.stomp_flag,

        CASE 
            WHEN p.player_slot < 128 AND mf.radiant_win = 1 THEN 1
            WHEN p.player_slot >= 128 AND mf.radiant_win = 0 THEN 1
            ELSE 0
        END AS player_win,

        LEAD(m.start_time) 
            OVER (PARTITION BY p.account_id ORDER BY m.start_time) 
            AS next_match_time

    FROM dota2.players p
    JOIN dota2.`match` m 
        ON p.match_id = m.match_id
    JOIN match_stomp_stats mss 
        ON m.match_id = mss.match_id 
    JOIN match_fairness mf
        ON m.match_id = mf.match_id

    WHERE p.account_id <> 0
)

-- ------------------------------------------------------------
-- Stomp loss session exit
-- ------------------------------------------------------------

SELECT 
    COUNT(*) AS stomp_losses,

    AVG(
        CASE 
            WHEN next_match_time IS NULL THEN 1
            ELSE 0
        END
    ) AS session_exit_rate

FROM player_events
WHERE stomp_flag = 1 AND player_win = 0;


-- ------------------------------------------------------------
-- Normal loss vs stomp loss
-- ------------------------------------------------------------

SELECT
    CASE
        WHEN stomp_flag = 1 THEN 'Stomp Loss'
        ELSE 'Normal Loss'
    END AS loss_type,

    COUNT(*) AS loss_events,

    AVG(
        CASE
            WHEN next_match_time IS NULL THEN 1
            ELSE 0
        END
    ) AS session_exit_rate

FROM player_events
WHERE player_win = 0
GROUP BY loss_type;


-- ------------------------------------------------------------
-- Win vs Loss
-- ------------------------------------------------------------

SELECT
    CASE
        WHEN player_win = 1 THEN 'Win'
        ELSE 'Loss'
    END AS outcome,

    COUNT(*) AS match_events,

    AVG(
        CASE
            WHEN next_match_time IS NULL THEN 1
            ELSE 0
        END
    ) AS session_exit_rate

FROM player_events
GROUP BY outcome;


-- ============================================================
-- PHASE 5 — BI-READY VIEWS FOR TABLEAU
-- ============================================================

-- ------------------------------------------------------------
-- Match-level BI mart
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW match_bi_master AS
WITH tiered AS (
    SELECT
        mf.match_id,
        mf.skill_gap,
        mf.skill_diff,
        mss.duration,
        mss.stomp_flag,

        (mf.radiant_skill + mf.dire_skill) / 2 AS avg_match_skill,
        m.start_time,

        CASE 
            WHEN mf.skill_gap <= 50 THEN 'Very Fair'
            WHEN mf.skill_gap <= 150 THEN 'Fair'
            WHEN mf.skill_gap <= 300 THEN 'Unbalanced'
            ELSE 'Stomp'
        END AS balance_category,

        NTILE(3) OVER (
            ORDER BY (mf.radiant_skill + mf.dire_skill) / 2
        ) AS skill_tier_num

    FROM match_fairness mf
    JOIN match_stomp_stats mss 
        ON mf.match_id = mss.match_id
    JOIN dota2.`match` m 
        ON mf.match_id = m.match_id
)

SELECT
    match_id,
    skill_gap,
    skill_diff,
    duration,
    stomp_flag,
    avg_match_skill,
    start_time,
    balance_category,

    CASE
        WHEN skill_tier_num = 1 THEN 'Low'
        WHEN skill_tier_num = 2 THEN 'Mid'
        WHEN skill_tier_num = 3 THEN 'High'
    END AS skill_tier

FROM tiered;


-- ------------------------------------------------------------
-- Player-session BI mart
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW player_session_bi AS
SELECT
    *,
    CASE 
        WHEN next_match_time IS NULL THEN 1
        ELSE 0
    END AS session_exit_flag
FROM (
    SELECT
        p.account_id,
        p.match_id,
        FROM_UNIXTIME(m.start_time) AS match_datetime,

        mss.stomp_flag,

        CASE 
            WHEN p.player_slot < 128 AND mf.radiant_win = 1 THEN 1
            WHEN p.player_slot >= 128 AND mf.radiant_win = 0 THEN 1
            ELSE 0
        END AS player_win,

        LEAD(FROM_UNIXTIME(m.start_time)) 
            OVER (PARTITION BY p.account_id ORDER BY m.start_time) 
            AS next_match_time

    FROM dota2.players p
    JOIN dota2.`match` m 
        ON p.match_id = m.match_id
    JOIN match_fairness mf
        ON m.match_id = mf.match_id
    JOIN match_stomp_stats mss
        ON m.match_id = mss.match_id

    WHERE p.account_id <> 0
) t;
