-- ============================================================================
-- BSC Validator Set Analysis v2 — counting only the 21 consensus nodes that
-- actually produced blocks
--
-- Difference from v1: v1 counts the 45 active validators elected each day
-- (candidate pool); v2 looks only at the 21 nodes that actually participate
-- in consensus block production each epoch.
--
-- Definition of "the 21 for the day" (confirmed by user):
--   The 21 actual block producers of the first epoch after UTC 00:00 that day.
--   Implementation: from bnb.blocks after 00:00, order miners by their first
--   block and take the first 21 distinct addresses = consensus set for that
--   epoch (empirically stable at exactly 21 per day).
--   Note: epoch length varies across hard forks and rotates multiple times
--   within a day (~30 visible in the window); the "first epoch" is used as the
--   representative daily snapshot.
--
-- Stake amount: joined from the same-day updateValidatorSetV2 45-set
--   (voting_power); staked_bnb = voting_power / 1e8 (= totalPooledBNB).
--
-- Time range: Feynman hard fork (mainnet 2024-04-18, first daily election
--   2024-04-19) through end of April 2026 (date < 2026-05-01).
-- ============================================================================


-- ============================================================================
-- Query 1: The 21 consensus nodes that actually produced blocks each day
--          (consensus address + stake), post-fork through 2026-04
-- ============================================================================
WITH blk AS (
    SELECT date AS day, number, miner
    FROM bnb.blocks
    WHERE date >= date '2024-04-18'
      AND date <  date '2026-05-01'
      AND hour(time) = 0 AND minute(time) < 20   -- window after 00:00, covers the first epoch
),
first_seen AS (
    SELECT day, miner, min(number) AS first_block
    FROM blk
    GROUP BY day, miner
),
-- Take the first 21 distinct block producers ordered by first block = consensus set of the day's first epoch
consensus21 AS (
    SELECT day, miner AS validator
    FROM (
        SELECT day, miner,
               row_number() OVER (PARTITION BY day ORDER BY first_block) AS rk
        FROM first_seen
    )
    WHERE rk <= 21
),
-- Stake weights from the same-day 45-set (from updateValidatorSetV2)
breathe_updates AS (
    SELECT
        block_time AS ts,
        CAST(date_trunc('day', block_time) AS date) AS day,
        "_consensusAddrs" AS validators,
        "_votingPowers"   AS powers
    FROM TABLE(
        decode_evm_function_call(
            abi => '{"name":"updateValidatorSetV2","type":"function","inputs":[{"name":"_consensusAddrs","type":"address[]"},{"name":"_votingPowers","type":"uint64[]"},{"name":"_voteAddrs","type":"bytes[]"}]}',
            data => TABLE(
                SELECT data AS input, CAST(NULL AS varbinary) AS output, block_time
                FROM bnb.transactions
                WHERE "to" = 0x0000000000000000000000000000000000001000
                  AND starts_with(data, 0x1e4c1524)
                  AND success
                  AND block_date >= date '2024-04-18'
                  AND block_date <  date '2026-05-01'
            )
        )
    )
),
daily_pick AS (
    SELECT *, row_number() OVER (PARTITION BY day ORDER BY ts DESC) AS rn
    FROM breathe_updates
),
set45 AS (
    SELECT p.day, t.validator, t.voting_power
    FROM daily_pick p
    CROSS JOIN UNNEST(p.validators, p.powers) AS t(validator, voting_power)
    WHERE p.rn = 1
)
SELECT
    c.day,
    c.validator,                              -- consensus address (actual block producer)
    s.voting_power,                           -- raw weight (uint64)
    s.voting_power / 1e8 AS staked_bnb        -- staked amount in BNB
FROM consensus21 c
LEFT JOIN set45 s ON s.day = c.day AND s.validator = c.validator
ORDER BY c.day DESC, s.voting_power DESC;


-- ============================================================================
-- Query 2: Weekly churn rate (21 consensus nodes, current week vs previous),
--          post-fork through 2026-04.
--          Uses the 21-set from the last snapshot day of each week for comparison.
-- ============================================================================
WITH blk AS (
    SELECT date AS day, number, miner
    FROM bnb.blocks
    WHERE date >= date '2024-04-18'
      AND date <  date '2026-05-01'
      AND hour(time) = 0 AND minute(time) < 20
),
first_seen AS (
    SELECT day, miner, min(number) AS first_block
    FROM blk GROUP BY day, miner
),
consensus21 AS (
    SELECT day, miner AS validator
    FROM (
        SELECT day, miner,
               row_number() OVER (PARTITION BY day ORDER BY first_block) AS rk
        FROM first_seen
    )
    WHERE rk <= 21
),
week_day AS (
    SELECT day, validator, CAST(date_trunc('week', day) AS date) AS week
    FROM consensus21
),
last_day AS (
    SELECT week, max(day) AS snap_day FROM week_day GROUP BY week
),
weekly_set AS (
    SELECT wd.week, wd.validator
    FROM week_day wd
    JOIN last_day ld ON wd.week = ld.week AND wd.day = ld.snap_day
),
compare AS (
    SELECT
        coalesce(cur.week, prev.week) AS week,
        cur.validator  AS cur_v,
        prev.validator AS prev_v
    FROM weekly_set cur
    FULL OUTER JOIN (
        SELECT week + interval '7' day AS week, validator FROM weekly_set
    ) prev
      ON cur.week = prev.week AND cur.validator = prev.validator
)
SELECT
    week,
    count(*) FILTER (WHERE cur_v  IS NOT NULL)                         AS validators_this_week,
    count(*) FILTER (WHERE prev_v IS NOT NULL)                         AS validators_prev_week,
    count(*) FILTER (WHERE cur_v IS NOT NULL AND prev_v IS NULL)       AS added,
    count(*) FILTER (WHERE cur_v IS NULL AND prev_v IS NOT NULL)       AS removed,
    count(*) FILTER (WHERE cur_v IS NOT NULL AND prev_v IS NOT NULL)   AS stayed,
    CAST(count(*) FILTER (WHERE cur_v IS NULL AND prev_v IS NOT NULL) AS double)
        / NULLIF(count(*) FILTER (WHERE prev_v IS NOT NULL), 0)        AS churn_rate
FROM compare
WHERE week >  (SELECT min(week) FROM weekly_set)
  AND week <= (SELECT max(week) FROM weekly_set)
GROUP BY week
ORDER BY week DESC;


-- ============================================================================
-- Query 3: Top-10 stake over time (21 consensus nodes only), post-fork through 2026-04.
--          Top 10 are ranked by stake in the 21-set on the last day of the range
--          (2026-04-30); daily staked BNB is back-filled for each.
--          Note: membership changes daily (the 21 rotate); days when a validator
--          is not in the 21-set produce no data point (gap in series).
-- ============================================================================
WITH blk AS (
    SELECT date AS day, number, miner
    FROM bnb.blocks
    WHERE date >= date '2024-04-18'
      AND date <  date '2026-05-01'
      AND hour(time) = 0 AND minute(time) < 20
),
first_seen AS (
    SELECT day, miner, min(number) AS first_block
    FROM blk GROUP BY day, miner
),
consensus21 AS (
    SELECT day, miner AS validator
    FROM (
        SELECT day, miner,
               row_number() OVER (PARTITION BY day ORDER BY first_block) AS rk
        FROM first_seen
    )
    WHERE rk <= 21
),
breathe_updates AS (
    SELECT
        block_time AS ts,
        CAST(date_trunc('day', block_time) AS date) AS day,
        "_consensusAddrs" AS validators,
        "_votingPowers"   AS powers
    FROM TABLE(
        decode_evm_function_call(
            abi => '{"name":"updateValidatorSetV2","type":"function","inputs":[{"name":"_consensusAddrs","type":"address[]"},{"name":"_votingPowers","type":"uint64[]"},{"name":"_voteAddrs","type":"bytes[]"}]}',
            data => TABLE(
                SELECT data AS input, CAST(NULL AS varbinary) AS output, block_time
                FROM bnb.transactions
                WHERE "to" = 0x0000000000000000000000000000000000001000
                  AND starts_with(data, 0x1e4c1524)
                  AND success
                  AND block_date >= date '2024-04-18'
                  AND block_date <  date '2026-05-01'
            )
        )
    )
),
daily_pick AS (
    SELECT *, row_number() OVER (PARTITION BY day ORDER BY ts DESC) AS rn
    FROM breathe_updates
),
set45 AS (
    SELECT p.day, t.validator, t.voting_power
    FROM daily_pick p
    CROSS JOIN UNNEST(p.validators, p.powers) AS t(validator, voting_power)
    WHERE p.rn = 1
),
-- 21 consensus nodes + stake amount
consensus_stake AS (
    SELECT c.day, c.validator, s.voting_power, s.voting_power / 1e8 AS staked_bnb
    FROM consensus21 c
    LEFT JOIN set45 s ON s.day = c.day AND s.validator = c.validator
),
latest_top AS (
    SELECT validator
    FROM consensus_stake
    WHERE day = (SELECT max(day) FROM consensus_stake)
    ORDER BY voting_power DESC
    LIMIT 10
)
SELECT
    day,
    concat('0x', lower(to_hex(validator))) AS validator,
    staked_bnb
FROM consensus_stake
WHERE validator IN (SELECT validator FROM latest_top)
ORDER BY day, staked_bnb DESC;
