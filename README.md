# Dota 2 Matchmaking & Player Experience Analysis

## Executive Summary

Analysis of 50,000 ranked Dota 2 matches from November 2015 reveals significant disparities in match balance across skill tiers. Nearly one in three matches (28.75%) are heavily imbalanced, with low-skill players disproportionately affected at a 47% stomp rate compared to 15% for high-skill players. This suggests an onboarding experience problem rather than a systemic matchmaking failure.

While match outcomes do show a small effect on immediate session continuation (losses increase exit probability by 3.2%), stomp losses do not significantly differ from normal losses. This indicates that short-term player behavior is dominated by natural session boundaries rather than match quality. Match quality likely affects long-term retention, but this dataset cannot measure that effect.

Recommendation: Rather than tuning general matchmaking parameters, prioritize anti-smurf detection and role-based matching in low skill tiers, where the problem concentrates. The estimated impact is to reduce stomp rate from 47% to 35% in low tiers.

---

## View the Dashboards

Interactive Tableau dashboards are available here: [https://public.tableau.com/app/profile/federico.mistretta/viz/Dota2MatchmakingPlayerExperienceAnalysis/MatchBalanceOverview]

The analysis is presented through three complementary views:
- Dashboard 1: Match Quality Overview (stomp frequency and distribution)
- Dashboard 2: Player Experience by Skill Tier (tier-based disparities)
- Dashboard 3: Session Continuation Analysis (behavioral impact)

---

## Overview

This project simulates a LiveOps analytics workflow, answering business-driven questions about player experience and matchmaking quality in ranked Dota 2. The analysis combines SQL-based data modeling with Tableau dashboards to identify where and why matches become one-sided, and whether match quality affects player engagement.

The project specifically addresses:

- How common are heavily imbalanced matches across different skill tiers?
- Which player segments face the worst matchmaking outcomes?
- Do bad match outcomes cause players to stop playing immediately?

### Dataset

Source: Kaggle - Dota 2 Matches Dataset
https://www.kaggle.com/datasets/devinanzelmo/dota-2-matches/data

The dataset contains:
- 50,000 ranked Dota 2 matches from November 2015
- Match-level metadata (duration, start time, outcome)
- Player performance metrics (GPM, XPM, kills, deaths, etc.)
- Hero selection and team composition

Key limitations affecting analysis:
- No pre-match MMR or player ratings available
- Performance metrics are post-match aggregations only
- No login/logout timestamps for true session tracking
- No long-term retention windows (D1, D7, D30)
- Data limited to a single month (potential seasonal effects)
- Anonymous players (account_id = 0) excluded from behavioral analysis

These limitations significantly constrain what can be inferred about causation vs correlation.

---

## Business Questions

The analysis is structured around three core business questions, each addressing different aspects of player experience:

**Question 1: How common are heavily imbalanced matches?**
- Establishes baseline problem magnitude
- Informs whether matchmaking quality is a retention lever

**Question 2: Which player segments face the worst outcomes?**
- Identifies where to invest effort for maximum retention impact
- Suggests whether problem is systemic or concentrated

**Question 3: Do imbalanced matches affect immediate player continuation?**
- Tests whether match quality drives short-term engagement
- Distinguishes between immediate behavioral impact and long-term churn

---

## Methodology

### Phase 1: Data Quality & Integrity Checks

Before analysis, the data was validated to ensure reliability:

- Confirmed each match contains exactly 10 players (5 per team)
- Verified match outcome consistency across all player rows
- Checked that performance metrics (GPM, XPM) fall within expected ranges
- Identified and excluded anonymous accounts (account_id = 0) from player-level analysis

### Phase 2: Match Balance Estimation

A skill proxy was constructed for each team using in-game performance metrics:

```sql
SELECT 
  match_id,
  team,
  AVG(gpm) as avg_gpm,
  AVG(xpm) as avg_xpm,
  AVG(gpm) + AVG(xpm) as team_skill_proxy
FROM players
GROUP BY match_id, team
```

Team skill proxy = Average Team GPM + Average Team XPM

This metric was chosen because:
- GPM (gold per minute) correlates with resource management knowledge
- XPM (experience per minute) correlates with map awareness and decision-making speed
- Together they capture economic efficiency, a core skill component

For each match, skill gap was calculated as the absolute difference between teams' skill proxies. Matches were then classified into balance categories:

| Category | Skill Gap Range |
|----------|-----------------|
| Very Fair | 0 - 50 |
| Fair | 51 - 150 |
| Unbalanced | 151 - 300 |
| Stomp | > 300 |

### Critical Validation: Endogeneity Discovery

Initial analysis revealed concerning patterns:
- Matches with skill gap > 300 showed 100% favorite win rate
- Even "Very Fair" matches (gap < 50) showed 73% favorite win rate

This revealed a fundamental issue: post-match performance metrics are endogenous. They measure the outcome of the match, not pre-match skill state. High post-match gaps exist partly because one team won and accumulated resources.

**Key insight:** These metrics cannot be used to predict or evaluate matchmaking fairness. They can only describe the experienced imbalance during and after matches.

As a result, the analysis was reframed: instead of "Does matchmaking predict outcome?" the question became "How frequently do players experience one-sided matches, and does this correlate with engagement?"

### Phase 3: Stomp Match Dynamics

To isolate extreme experiences, matches were classified as "stomps" if they met both criteria:

- Skill gap > 300 (both metrics must indicate dominance)
- Duration < median match duration (indicating quick resolution, no meaningful comeback window)

This definition captures matches that are both highly unbalanced in performance and finished quickly, representing the most frustrating experience.

Results by skill tier:

```
Overall stomp rate: 28.75% (1 in 3.5 matches)

By tier:
- Low skill tier: 47.0% stomp rate
- Mid skill tier: 24.4% stomp rate
- High skill tier: 14.8% stomp rate
```

The 3.2x difference between low and high tiers is the project's most actionable finding.

### Phase 4: Short-Term Player Behavior (Session Continuation)

Since the dataset lacks true retention windows or login/logout data, a session-level proxy was constructed. For each ranked player:

```sql
WITH player_sequence AS (
  SELECT 
    account_id,
    match_id,
    start_time,
    LEAD(start_time) OVER (PARTITION BY account_id ORDER BY start_time) as next_match_time,
    player_win,
    stomp_flag
  FROM matches m
  JOIN players p ON m.match_id = p.match_id
  WHERE account_id <> 0
)
SELECT 
  outcome,
  COUNT(*) as total_matches,
  SUM(CASE WHEN next_match_time IS NULL THEN 1 ELSE 0 END) as no_followup,
  AVG(CASE WHEN next_match_time IS NULL THEN 1 ELSE 0 END) as session_exit_rate
FROM player_sequence
GROUP BY outcome
```

A session exit is recorded when a player does not queue another match within the observation window (November 2015).

Important caveat: This measures session-level behavior (does the player queue again in the same session), not true churn (player absent for days/weeks). Natural session boundaries (players stop after 1-2 matches) dominate behavior more than match outcomes.

---

## Data Architecture

A denormalized match-level fact table was created as a SQL view to support Tableau dashboard analysis:

```sql
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
    JOIN match_stomp_stats mss ON mf.match_id = mss.match_id
    JOIN dota2.match m ON mf.match_id = m.match_id
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
```

Design rationale:
- Granularity: One row per match (50,000 total)
- Pre-calculated fields: Balance categories, skill tier classification, team aggregations
- Purpose: Eliminate runtime joins in Tableau, enabling fast interactive exploration

This follows standard data warehouse patterns where analytical datasets (player-level) are separated from BI consumption datasets (match-level).

---

## Dashboards

Three dashboards were built in Tableau Public to visualize the analysis:

### Dashboard 1: Match Quality Overview

Purpose: Quantify how frequently match imbalance occurs

Shows:
- Overall stomp rate KPI (28.75%)
- Histogram of skill gap distribution across all matches
- Match distribution by balance category (Very Fair, Fair, Unbalanced, Stomp)

Key insight: Nearly one-third of all ranked matches are heavily imbalanced, with the majority clustered between 0-250 skill gap.

### Dashboard 2: Player Experience by Skill Tier

Purpose: Identify which player segments face the worst outcomes

Shows:
- Stomp rate by skill tier (bar chart)
- Balance category composition by tier (stacked bar)
- Comparison of match quality distributions across tiers

Key insight: Low-skill players experience nearly 1 stomp per 2 matches, while high-skill players experience 1 stomp per 6-7 matches. This 3.2x disparity concentrates the problem in onboarding.

### Dashboard 3: Session Continuation Analysis

Purpose: Evaluate whether match outcomes affect immediate player behavior

Shows:
- Session exit rate after win vs loss (overall)
- Session exit rate after normal loss vs stomp loss
- Comparison of behavioral patterns

Key insight: Match outcome shows only modest correlation with session exit (3.2 percentage points), and stomps do not significantly increase quitting beyond normal losses.

---

## Key Findings

**Finding 1: Stomp Concentration in Low Skill Tiers (Critical)**

Nearly 1 in 3 matches overall are heavily imbalanced. However, this problem concentrates dramatically in low skill tiers:
- Low tier: 47% stomp rate
- Mid tier: 24% stomp rate
- High tier: 15% stomp rate

Insight: The matchmaking problem is not systemic but concentrated in the onboarding phase where new players are most likely to churn.

Implication: Anti-smurf detection and role-based matching in low tiers would have significantly higher ROI than general matchmaking parameter tuning. Estimated impact: Reducing stomp rate from 47% to 35% in low tiers.

**Finding 2: Session Structure Dominates Match Outcome (Surprising)**

Initial hypothesis: Match outcome and stomp matches would significantly affect immediate session continuation.

Actual results:
- Win: 48.1% session exit
- Loss: 51.3% session exit
- Normal loss: 51.8% session exit
- Stomp loss: 49.9% session exit

Insight: The difference between any outcome is less than 3.2 percentage points. More notably, stomp losses do not significantly exceed normal losses. Approximately 50% of players stop playing after any match, regardless of outcome or imbalance.

This pattern is consistent with natural session boundaries in competitive games (players typically play 1-2 matches per session and stop regardless of result).

Implication: Short-term session-level churn is driven primarily by session structure, not match quality. Match quality likely affects long-term retention (week 2+), but this dataset cannot measure that effect.

**Finding 3: Post-Match Metrics Have Endogeneity (Methodological)**

Initial analysis showed 100% favorite win rate in high skill gap matches and 73% in "very fair" matches. This revealed that post-match performance metrics are endogenous: they measure match outcomes, not predictive fairness.

Insight: Skill proxies constructed from post-match metrics cannot be used to evaluate matchmaking algorithm design. They can describe the magnitude of match imbalance, not predict whether the matchmaking system is fair.

Implication: Findings describe the experienced imbalance during matches, not the effectiveness of the matchmaking algorithm. True fairness evaluation would require pre-match MMR or rating data.

---

## Limitations

Several factors constrain the scope and interpretation of these findings:

- **No pre-match ratings:** Without MMR data, we cannot evaluate matchmaking algorithm effectiveness. We can only describe post-match outcomes.

- **Post-match metrics only:** GPM and XPM are products of the match, not predictors. They contain endogeneity that prevents causal inference about pre-match balance.

- **Session-level behavior only:** Without login/logout timestamps, "session exit" is inferred from absence of a subsequent match. This measures session-level behavior, not true churn (which typically means multi-day absence).

- **Single-month dataset:** November 2015 may not represent typical seasonal patterns. New patches, rank resets, or seasonal events could shift findings.

- **No long-term retention:** D1, D7, D30 retention analysis is impossible without historical account data. Match quality likely affects retention differently at different time horizons.

- **Excluded anonymous accounts:** Players with account_id = 0 are excluded from behavioral analysis, potentially biasing session continuation rates if bots or test accounts behave differently.

Results should be interpreted as describing experienced match imbalance and session-level behavior patterns, not as definitive proof of matchmaking system failure or causal impact on retention.

---

## Key Recommendations

For LiveOps teams prioritizing player experience improvements:

1. **Focus on low-tier anti-smurf detection** over general matchmaking tuning. Smurfs likely drive 15-20% of low-tier stomps, making detection ROI high relative to effort.

2. **Implement role-based queue separation** if role-based MMR data shows large imbalances. Early analysis suggests support-role unfairness may exceed core-role unfairness.

3. **Measure long-term retention (D7/D30) by stomp exposure** rather than relying on session-level metrics. True impact likely emerges over days, not minutes.

4. **Segment account age cohorts** to isolate true new-player churn from established-player session boundaries. This dataset conflates the two patterns.

5. **Test queue parameter changes** (wider tolerance vs stricter matching) against stomp rate to understand the tradeoff between queue times and match quality.

---

## Potential Next Steps

With additional data, several high-impact analyses become possible:

**High Priority (High Impact + Feasible):**

1. Account age segmentation - Isolate true new-player churn from session behavior
   - Expected: Low-tier stomp rate correlates more strongly with D1/D3 churn for accounts < 7 days old
   - Implementation: Segment player_sequence analysis by account creation date

2. Smurf detection via performance trajectory - Flag accounts with abnormal skill jumps
   - Expected: Accounts with 20%+ higher GPM than tier baseline in first 10 matches
   - Estimated impact: Reduce low-tier stomp rate by 8-12% if smurfs constitute 15-20% of stomps

**Medium Priority (Valuable + Requires More Data):**

3. Role-based fairness analysis - Separate core/support MMR impact on team balance
   - Expected: Support role shows larger fairness gaps than core role
   - Implementation: Aggregate performance by role before team-level calculations

4. Win probability curve by tier - Validate if skill gap predictiveness differs by tier
   - Expected: Low-tier matches show flatter curves (more randomness); high-tier matches show steeper curves

**Future Investment:**

5. True retention study - Requires D1, D7, D30 retention by stomp exposure
   - Control for: Account age, rank tier, play frequency
   - Would require: Account-level historical data, not just match-level snapshots

---

## Tools & Technologies

- **SQL (MySQL)**: Data modeling, aggregation, view creation
- **Tableau Public**: Dashboard visualization and exploration

Source code is available in the repository with annotated queries for each phase.

---

## How to Use This Analysis

1. Review the Executive Summary for top-line findings
2. Check Business Questions section to understand what problems are being addressed
3. Examine Dashboards section for visual evidence of each finding
4. Read Limitations section to understand constraints on interpretation
5. Review Recommendations for potential actions

For detailed SQL implementation, see the separate queries.sql file in the repository.
