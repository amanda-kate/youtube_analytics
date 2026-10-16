DROP VIEW IF EXISTS v_capture;
DROP VIEW IF EXISTS v_keyword_health_scores;
DROP VIEW IF EXISTS v_keyword_health;
DROP VIEW IF EXISTS v_risk;

-- ---------------------------------------------------------------------
-- v_risk: one row per scored video with 10+ comments
--   controversy = 2 * min(pct_pos, pct_neg)   (0 to 1; peaks at a 50/50 split)
--   neg_flag    = pct_neg at or above the 90th percentile
--   risk_score  = average percent rank of pct_neg and controversy
--   priority    = risk_score * LN(1 + views)  (risk weighted by reach)
--   endorsed_neg is NOT part of the risk score. It is held out as the
--   outcome the triage simulation is evaluated against.
-- ---------------------------------------------------------------------
CREATE VIEW v_risk AS
WITH base AS (
  SELECT
    m.video_id, m.title, m.keyword, m.views, m.engagement_rate, m.quality_score,
    s.n_comments,
    s.pct_pos::float8       AS pct_pos,
    s.pct_neg::float8       AS pct_neg,
    s.net_sentiment::float8 AS net_sentiment,
    2 * LEAST(s.pct_pos, s.pct_neg)::float8 AS controversy,
    COALESCE(e.endorsed_neg, 0) AS endorsed_neg
  FROM v_scored m
  JOIN v_sentiment s ON s.video_id = m.video_id AND s.n_comments >= 10
  LEFT JOIN v_endorsed e ON e.video_id = m.video_id
),
th AS (
  SELECT PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY pct_neg) AS p90_neg FROM base
),
ranked AS (
  SELECT
    b.*,
    (b.pct_neg >= th.p90_neg) AS neg_flag,
    (PERCENT_RANK() OVER (ORDER BY b.pct_neg)
   + PERCENT_RANK() OVER (ORDER BY b.controversy)) / 2 AS risk_score
  FROM base b CROSS JOIN th
)
SELECT *, risk_score * LN(1 + views::float8) AS priority
FROM ranked;

-- ---------------------------------------------------------------------
-- v_keyword_health: components of the health score (at least 5 videos)
-- ---------------------------------------------------------------------
CREATE VIEW v_keyword_health AS
SELECT
  keyword,
  COUNT(*)              AS scored_videos,
  -- averages are rounded to 10 decimals so floating-point noise cannot
  -- turn mathematically equal values into false differences when ranking
  ROUND(AVG(net_sentiment)::numeric, 10) AS avg_net_sentiment,
  ROUND(AVG(neg_flag::int), 10)          AS flag_rate,
  ROUND(AVG(controversy)::numeric, 10)   AS avg_controversy,
  SUM(endorsed_neg)     AS endorsed_neg_total
FROM v_risk
GROUP BY keyword
HAVING COUNT(*) >= 5;

-- ---------------------------------------------------------------------
-- v_keyword_health_scores: 0-100 health score under three weight sets
--   Each component is rescaled across keywords with percent rank:
--     sentiment (higher is healthier), flag rate and controversy (lower is healthier)
--   Weights (sentiment / flag rate / controversy):
--     A = 40 / 30 / 30 (default)   B = 60 / 20 / 20 (sentiment-heavy)
--     C = 20 / 40 / 40 (risk-heavy)
--   rank_spread = how far a keyword's rank moves across the three scenarios
--   (these weights are assumptions; see docs/assumptions_log.xlsx)
-- ---------------------------------------------------------------------
CREATE VIEW v_keyword_health_scores AS
WITH pr AS (
  SELECT
    h.*,
    PERCENT_RANK() OVER (ORDER BY avg_net_sentiment)     AS pr_sent,
    1 - PERCENT_RANK() OVER (ORDER BY flag_rate)         AS pr_flag_inv,
    1 - PERCENT_RANK() OVER (ORDER BY avg_controversy)   AS pr_contro_inv
  FROM v_keyword_health h
),
sc AS (
  SELECT
    pr.*,
    ROUND((100 * (0.4 * pr_sent + 0.3 * pr_flag_inv + 0.3 * pr_contro_inv))::numeric, 6) AS health_a,
    ROUND((100 * (0.6 * pr_sent + 0.2 * pr_flag_inv + 0.2 * pr_contro_inv))::numeric, 6) AS health_b,
    ROUND((100 * (0.2 * pr_sent + 0.4 * pr_flag_inv + 0.4 * pr_contro_inv))::numeric, 6) AS health_c
  FROM pr
),
rk AS (
  SELECT
    sc.*,
    RANK() OVER (ORDER BY health_a DESC) AS rank_a,
    RANK() OVER (ORDER BY health_b DESC) AS rank_b,
    RANK() OVER (ORDER BY health_c DESC) AS rank_c
  FROM sc
)
SELECT
  rk.*,
  GREATEST(rank_a, rank_b, rank_c) - LEAST(rank_a, rank_b, rank_c) AS rank_spread
FROM rk;

-- ---------------------------------------------------------------------
-- v_capture: triage simulation
--   If a team can review only the top K videos, what share of all
--   audience-endorsed negative comments sits in the videos it reviews?
--   Strategies:
--     risk x reach           ranked by priority
--     negativity then views  ranked by pct_neg, ties broken by views
--     views only             ranked by views
--     ideal (upper bound)    ranked by endorsed_neg (hindsight)
--     random (expected)      the diagonal: k / n
-- ---------------------------------------------------------------------
CREATE VIEW v_capture AS
WITH s AS (
  SELECT video_id, views, pct_neg, priority, endorsed_neg,
         COUNT(*)            OVER () AS n,
         SUM(endorsed_neg)   OVER () AS total
  FROM v_risk
)
SELECT 'risk x reach' AS strategy,
  ROW_NUMBER() OVER (ORDER BY priority DESC, video_id) AS k, n,
  SUM(endorsed_neg) OVER (ORDER BY priority DESC, video_id)::float8 / total AS cum_capture
FROM s
UNION ALL
SELECT 'negativity then views',
  ROW_NUMBER() OVER (ORDER BY pct_neg DESC, views DESC, video_id), n,
  SUM(endorsed_neg) OVER (ORDER BY pct_neg DESC, views DESC, video_id)::float8 / total
FROM s
UNION ALL
SELECT 'views only',
  ROW_NUMBER() OVER (ORDER BY views DESC, video_id), n,
  SUM(endorsed_neg) OVER (ORDER BY views DESC, video_id)::float8 / total
FROM s
UNION ALL
SELECT 'ideal (upper bound)',
  ROW_NUMBER() OVER (ORDER BY endorsed_neg DESC, video_id), n,
  SUM(endorsed_neg) OVER (ORDER BY endorsed_neg DESC, video_id)::float8 / total
FROM s
UNION ALL
SELECT 'random (expected)',
  ROW_NUMBER() OVER (ORDER BY video_id), n,
  ROW_NUMBER() OVER (ORDER BY video_id)::float8 / n
FROM s;

-- =====================================================================
-- ANALYSIS QUERIES (run one at a time)
-- =====================================================================

-- A. Keyword health scores (default weights) with sensitivity ranks
SELECT keyword, scored_videos,
       ROUND(avg_net_sentiment::numeric, 3) AS avg_net_sentiment,
       ROUND(flag_rate::numeric, 3)         AS flag_rate,
       ROUND(avg_controversy::numeric, 3)   AS avg_controversy,
       ROUND(health_a::numeric, 1) AS health_a,
       rank_a, rank_b, rank_c, rank_spread
FROM v_keyword_health_scores
ORDER BY health_a DESC;

-- B. Review queue: top 25 videos by priority
SELECT video_id, title, keyword, views, n_comments,
       ROUND(pct_neg::numeric, 2) AS pct_neg,
       ROUND(controversy::numeric, 2) AS controversy,
       endorsed_neg, ROUND(priority::numeric, 2) AS priority
FROM v_risk ORDER BY priority DESC LIMIT 25;

-- C. Flagged videos (high negative share) per keyword
SELECT keyword, COUNT(*) FILTER (WHERE neg_flag) AS flagged_videos, COUNT(*) AS scored_videos
FROM v_risk GROUP BY keyword ORDER BY flagged_videos DESC;

-- D. Capture summary: share of endorsed negatives caught at 5%, 10%, 20% review capacity
SELECT strategy,
  ROUND(MAX(cum_capture) FILTER (WHERE k = CEIL(0.05 * n))::numeric, 3) AS at_5pct,
  ROUND(MAX(cum_capture) FILTER (WHERE k = CEIL(0.10 * n))::numeric, 3) AS at_10pct,
  ROUND(MAX(cum_capture) FILTER (WHERE k = CEIL(0.20 * n))::numeric, 3) AS at_20pct
FROM v_capture GROUP BY strategy ORDER BY at_10pct DESC;

-- =====================================================================
-- CHECKS: run these one at a time and compare with the expected values
-- =====================================================================

-- 1. Scored videos with 10+ comments. Expect 1,759.
SELECT COUNT(*) AS risk_rows FROM v_risk;

-- 2. Flagged videos. Expect 198 (the 90th-percentile negative share is 0.4).
SELECT COUNT(*) FILTER (WHERE neg_flag) AS flagged FROM v_risk;

-- 3. Endorsed negatives inside v_risk. Expect 318 comments across 232 videos.
SELECT SUM(endorsed_neg) AS total_endorsed,
       COUNT(*) FILTER (WHERE endorsed_neg > 0) AS videos_with_endorsed FROM v_risk;

-- 4. Keywords scored. Expect 41.
SELECT COUNT(*) AS keywords FROM v_keyword_health_scores;

-- 5. Healthiest 3 and least healthy 3 under the default weights. Expect:
--    top: lofi (100.0), music (98.3), asmr (95.5)
--    bottom: news (3.3), history (5.8), then cnn and trolling tied at 6.0
(SELECT keyword, ROUND(health_a::numeric, 2) AS health_a, rank_a FROM v_keyword_health_scores ORDER BY health_a DESC LIMIT 3)
UNION ALL
(SELECT keyword, ROUND(health_a::numeric, 2), rank_a FROM v_keyword_health_scores ORDER BY health_a ASC, keyword LIMIT 4);

-- 6. Rank stability. Expect max rank_spread 11, and 38 keywords with a spread of 5 or less.
SELECT MAX(rank_spread) AS max_spread,
       COUNT(*) FILTER (WHERE rank_spread <= 5) AS keywords_within_5
FROM v_keyword_health_scores;

-- 7. Highest flag rates. Expect cnn (about 0.755), then news (about 0.647).
SELECT keyword, ROUND(flag_rate::numeric, 3) AS flag_rate
FROM v_keyword_health ORDER BY flag_rate DESC LIMIT 2;

-- 8. Top priority video. Expect xuCn8ux2gbs (history, about 147 million views).
SELECT video_id, keyword, views FROM v_risk ORDER BY priority DESC LIMIT 1;

-- 9. Capture at 10% review capacity (176 videos). Expect about:
--    risk x reach 0.50 | negativity then views 0.34 | views only 0.21
--    ideal 0.82 | random 0.10
--    (small differences are possible where videos tie on the ranking score)
SELECT strategy, ROUND(cum_capture::numeric, 3) AS capture_at_10pct
FROM v_capture WHERE k = CEIL(0.10 * n) ORDER BY cum_capture DESC;
