-- =====================================================================
-- YouTube Content Strategy: Phase 2 (success drivers)
-- PostgreSQL. Requires the Phase 1 views (v_clean, v_sentiment).
-- In DBeaver, run the whole file with Alt+X (Execute Script).
-- Run order: 01, then 02, then 03.
-- Re-running: this script drops v_scored and v_metrics, which Phase 3 views
-- depend on. If Phase 3 views exist, run the DROP VIEW lines at the top of 03 first.
-- =====================================================================

DROP VIEW IF EXISTS v_keyword_leaderboard;
DROP VIEW IF EXISTS v_rank_compare;
DROP VIEW IF EXISTS v_video_summary;
DROP VIEW IF EXISTS v_scored;
DROP VIEW IF EXISTS v_metrics;

-- ---------------------------------------------------------------------
-- v_metrics: engagement metrics per video
--   * only videos with visible likes AND enabled comments (NULLs excluded;
--     PostgreSQL sorts NULLs last, which would otherwise rank them highest)
--   reach_score     = views + likes + comments (in practice this ranks by views)
--   like_view_ratio = likes / views
--   comment_rate    = comments / views
--   engagement_rate = (likes + comments) / views
-- ---------------------------------------------------------------------
CREATE VIEW v_metrics AS
SELECT
  c.*,
  likes::float8 / views                AS like_view_ratio,
  comments::float8 / views             AS comment_rate,
  (likes + comments)::float8 / views   AS engagement_rate,
  views + likes + comments             AS reach_score
FROM v_clean c
WHERE likes IS NOT NULL AND comments IS NOT NULL;

-- ---------------------------------------------------------------------
-- v_scored: quality score and within-keyword deciles
--   quality_score    = average percent rank of views, like_view_ratio,
--                      and comment_rate (0 to 1; higher is better)
--   decile_in_keyword = 10 means top 10% by engagement rate in its keyword
-- ---------------------------------------------------------------------
CREATE VIEW v_scored AS
SELECT
  m.*,
  (PERCENT_RANK() OVER (ORDER BY views)
 + PERCENT_RANK() OVER (ORDER BY like_view_ratio)
 + PERCENT_RANK() OVER (ORDER BY comment_rate)) / 3          AS quality_score,
  NTILE(10) OVER (PARTITION BY keyword ORDER BY engagement_rate) AS decile_in_keyword
FROM v_metrics m;

-- ---------------------------------------------------------------------
-- v_video_summary: one row per scored video, with sentiment attached
--   sentiment columns are NULL unless the video has 10+ comments
--   (this is the main table for Tableau)
-- ---------------------------------------------------------------------
CREATE VIEW v_video_summary AS
SELECT
  sc.*,
  s.n_comments, s.pct_pos, s.pct_neu, s.pct_neg, s.net_sentiment
FROM v_scored sc
LEFT JOIN v_sentiment s
  ON s.video_id = sc.video_id AND s.n_comments >= 10;

-- ---------------------------------------------------------------------
-- v_rank_compare: reach rank vs quality rank
--   rank_gap = reach_rank - quality_rank
--     large positive = quality outranks reach ("hidden gem")
--     large negative = big reach, weaker engagement quality
-- ---------------------------------------------------------------------
CREATE VIEW v_rank_compare AS
SELECT
  video_id, title, keyword, views, engagement_rate, reach_score, quality_score,
  RANK() OVER (ORDER BY reach_score DESC)   AS reach_rank,
  RANK() OVER (ORDER BY quality_score DESC) AS quality_rank,
  RANK() OVER (ORDER BY reach_score DESC)
    - RANK() OVER (ORDER BY quality_score DESC) AS rank_gap
FROM v_scored;

-- ---------------------------------------------------------------------
-- v_keyword_leaderboard: medians by keyword (at least 10 videos)
-- ---------------------------------------------------------------------
CREATE VIEW v_keyword_leaderboard AS
SELECT
  keyword,
  COUNT(*)                                                          AS videos,
  COUNT(net_sentiment)                                              AS videos_with_sentiment,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY views::float8)        AS median_views,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY engagement_rate)      AS median_engagement,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY like_view_ratio)      AS median_like_view,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY comment_rate)         AS median_comment_rate,
  AVG(net_sentiment)                                                AS avg_net_sentiment,
  AVG(quality_score)                                                AS avg_quality_score
FROM v_video_summary
GROUP BY keyword
HAVING COUNT(*) >= 10;

-- =====================================================================
-- ANALYSIS QUERIES (run one at a time)
-- =====================================================================

-- A. Keyword leaderboard by median engagement
SELECT * FROM v_keyword_leaderboard ORDER BY median_engagement DESC;

-- B. Top 20 videos by reach
SELECT video_id, title, keyword, views, engagement_rate, reach_rank, quality_rank
FROM v_rank_compare ORDER BY reach_rank LIMIT 20;

-- C. Top 20 videos by quality
SELECT video_id, title, keyword, views, engagement_rate, reach_rank, quality_rank
FROM v_rank_compare ORDER BY quality_rank LIMIT 20;

-- D. Biggest disagreements: quality far above reach ("hidden gems")
SELECT video_id, title, keyword, views, engagement_rate, reach_rank, quality_rank, rank_gap
FROM v_rank_compare ORDER BY rank_gap DESC LIMIT 20;

-- E. Biggest disagreements: reach far above quality
SELECT video_id, title, keyword, views, engagement_rate, reach_rank, quality_rank, rank_gap
FROM v_rank_compare ORDER BY rank_gap ASC LIMIT 20;

-- F. Top-decile videos within each keyword (count per keyword)
SELECT keyword, COUNT(*) AS top_decile_videos
FROM v_scored WHERE decile_in_keyword = 10
GROUP BY keyword ORDER BY top_decile_videos DESC;

-- G. Data quality note (do not treat as a finding): videos excluded from the metrics
SELECT COUNT(*) FILTER (WHERE likes IS NULL)    AS hidden_likes,
       COUNT(*) FILTER (WHERE comments IS NULL) AS comments_disabled
FROM v_clean;

-- =====================================================================
-- CHECKS: run these one at a time and compare with the expected values
-- =====================================================================

-- 1. Scored videos. Expect 1,858.
SELECT COUNT(*) AS scored_videos FROM v_scored;

-- 2. Videos with sentiment attached. Expect 1,759.
SELECT COUNT(net_sentiment) AS videos_with_sentiment FROM v_video_summary;

-- 3. Keywords in the leaderboard. Expect 41 (all of them).
SELECT COUNT(*) AS keywords FROM v_keyword_leaderboard;

-- 4. Top 5 keywords by median engagement. Expect, in order:
--    crypto (about 0.0847), reaction (0.0648), nintendo (0.0504),
--    asmr (0.0501), trolling (0.0483)
--    (asmr and nintendo changed slightly after the dedupe tie-break fix in Phase 1)
SELECT keyword, ROUND(median_engagement::numeric, 4) AS median_engagement
FROM v_keyword_leaderboard ORDER BY median_engagement DESC LIMIT 5;

-- 5. Bottom 3 keywords. Expect: movies (0.0065), animals (0.0079), sports (0.0117)
SELECT keyword, ROUND(median_engagement::numeric, 4) AS median_engagement
FROM v_keyword_leaderboard ORDER BY median_engagement ASC LIMIT 3;

-- 6. Top video by reach. Expect video_id FzG4uDgje3M with about 4.03 billion views.
SELECT video_id, views FROM v_rank_compare ORDER BY reach_rank LIMIT 1;

-- 7. Overall median engagement rate. Expect about 0.0304.
SELECT ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY engagement_rate))::numeric, 4)
       AS median_engagement FROM v_scored;