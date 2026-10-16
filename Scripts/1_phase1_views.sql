DROP VIEW IF EXISTS v_endorsed;
DROP VIEW IF EXISTS v_sentiment;
DROP VIEW IF EXISTS v_clean;

-- ---------------------------------------------------------------------
-- v_clean: one row per video
--   * keeps the highest-views row when a video_id appears twice
--   * drops rows with NULL or zero views (the 2 blank rows)
--   * turns hidden likes / disabled comments (-1) into NULL, and keeps
--     "comments disabled" as its own flag
--   * decodes common HTML entities in titles
-- ---------------------------------------------------------------------
CREATE VIEW v_clean AS
SELECT DISTINCT ON (video_id)
  video_id,
  REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(title,
    '&#39;', ''''), '&amp;', '&'), '&quot;', '"'), '&lt;', '<'), '&gt;', '>') AS title,
  published_at,
  keyword,
  views,
  NULLIF(likes, -1)    AS likes,
  NULLIF(comments, -1) AS comments,
  (comments = -1)      AS comments_disabled
FROM videos
WHERE views > 0
-- 8 of the 12 duplicated video_ids have identical views under both keywords,
-- so ties are broken alphabetically by keyword (binary order) to keep results repeatable.
-- If the Phase 2/3 views already exist, do not re-run this file: use
-- CREATE OR REPLACE VIEW v_clean with this same body instead.
ORDER BY video_id, views DESC, keyword COLLATE "C";

-- ---------------------------------------------------------------------
-- v_sentiment: one row per video that has comments
--   sentiment codes: 0 = negative, 1 = neutral, 2 = positive
--   net_sentiment = % positive minus % negative
-- ---------------------------------------------------------------------
CREATE VIEW v_sentiment AS
SELECT
  video_id,
  COUNT(*)                                              AS n_comments,
  AVG((sentiment = 2)::int)                             AS pct_pos,
  AVG((sentiment = 1)::int)                             AS pct_neu,
  AVG((sentiment = 0)::int)                             AS pct_neg,
  AVG((sentiment = 2)::int) - AVG((sentiment = 0)::int) AS net_sentiment
FROM comments
GROUP BY video_id;

-- ---------------------------------------------------------------------
-- v_endorsed: audience-endorsed negativity
--   a negative comment whose likes are at or above the 90th percentile
--   of comment likes (among comments with at least 1 like).
--   Sensitivity test later: change 0.9 to 0.75.
-- ---------------------------------------------------------------------
CREATE VIEW v_endorsed AS
WITH t AS (
  SELECT PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY likes) AS p90
  FROM comments
  WHERE likes > 0
)
SELECT c.video_id, COUNT(*) AS endorsed_neg
FROM comments c
CROSS JOIN t
WHERE c.sentiment = 0 AND c.likes >= t.p90
GROUP BY c.video_id;

