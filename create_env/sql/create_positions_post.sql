-- =========================================================
-- 08_create_positions.sql
-- Positions report with FIFO lot netting and dual-currency
-- valuation.
--
-- NOTE: p_settled and p_lots are typed as the enum art_yn, so
-- their value domains live in the catalog (pg_enum) and can be
-- resolved automatically by the ART onboarder. This is the
-- introspectable counterpart to transactions_listing, whose
-- equivalent params are validated in the function body and must
-- therefore be declared by hand during ART setup.
-- =========================================================

DO $$ BEGIN
    CREATE TYPE public.art_yn AS ENUM ('Y','N');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


DROP FUNCTION IF EXISTS public.positions(integer, integer, public.art_yn, date, public.art_yn);

CREATE OR REPLACE FUNCTION public.positions
(
    p_entity_id   integer,
    p_group_id    integer,
    p_settled     public.art_yn,
    p_as_of_date  date,
    p_lots        public.art_yn
)
RETURNS TABLE
(
    scope_type              text,
    scope_id                integer,
    entity_id               integer,
    entity_name             text,
    entity_currency         text,
    security_id             integer,
    identifier              text,
    security_name           text,
    security_type           text,
    security_currency       text,
    transaction_id          bigint,
    trade_date              date,
    units                   numeric(18,4),
    cost_foreign            numeric(18,2),
    market_value_foreign    numeric(18,2),
    cost_local              numeric(18,2),
    market_value_local      numeric(18,2),
    fx_rate                 numeric(18,8),
    fx_rate_cost            numeric(18,8),
    cost_per_unit_foreign   numeric(18,6),
    price_per_unit_foreign  numeric(18,4)
)
LANGUAGE plpgsql
AS $$
BEGIN
    ----------------------------------------------------------
    -- param validation
    ----------------------------------------------------------
    IF (p_entity_id IS NULL AND p_group_id IS NULL)
       OR (p_entity_id IS NOT NULL AND p_group_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Exactly one of p_entity_id or p_group_id must be supplied';
    END IF;

    IF p_as_of_date IS NULL THEN
        RAISE EXCEPTION 'p_as_of_date is required';
    END IF;

    ----------------------------------------------------------
    -- report
    ----------------------------------------------------------
    RETURN QUERY
    WITH scoped_entities AS
    (
        SELECT e.entity_id
        FROM public.entities e
        WHERE p_entity_id IS NOT NULL
          AND e.entity_id = p_entity_id

        UNION

        SELECT g.entity_id
        FROM public.groups g
        WHERE p_group_id IS NOT NULL
          AND g.group_id = p_group_id
    ),

    -- transactions in scope, cut off per the settled convention:
    --   'Y' -> settled as at as_of_date
    --   'N' -> traded  as at as_of_date  (superset of 'Y')
    txn AS
    (
        SELECT t.*
        FROM public.transactions t
        JOIN scoped_entities se ON se.entity_id = t.fund_id
        WHERE ( p_settled = 'N' AND t.trade_date      <= p_as_of_date )
           OR ( p_settled = 'Y' AND t.settlement_date <= p_as_of_date )
    ),

    sells AS
    (
        SELECT x.fund_id, x.security_id, SUM(x.units) AS sold_units
        FROM txn x
        WHERE x.transaction_type = 'SELL'
        GROUP BY x.fund_id, x.security_id
    ),

    -- cumulative BUY units strictly before each lot, in FIFO order
    buys AS
    (
        SELECT
            x.*,
            COALESCE(
                SUM(x.units) OVER (PARTITION BY x.fund_id, x.security_id
                                   ORDER BY x.trade_date, x.transaction_id
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
            , 0) AS prior_buy_units
        FROM txn x
        WHERE x.transaction_type = 'BUY'
    ),

    -- FIFO consumption: sells eat the oldest lots first.
    -- open = clamp(units, 0, prior + units - sold)
    open_lots AS
    (
        SELECT
            b.transaction_id,
            b.fund_id,
            b.security_id,
            b.trade_date,
            b.units                                   AS lot_units,
            b.net_amount,
            b.net_amount_local,
            GREATEST(
                0,
                LEAST(
                    b.units,
                    b.prior_buy_units + b.units - COALESCE(s.sold_units, 0)
                )
            )                                         AS open_units
        FROM buys b
        LEFT JOIN sells s
               ON s.fund_id     = b.fund_id
              AND s.security_id = b.security_id
    ),

    -- one row per lot when p_lots = 'Y', otherwise one row per
    -- entity + security
    agg AS
    (
        SELECT
            o.fund_id,
            o.security_id,
            CASE WHEN p_lots = 'Y' THEN o.transaction_id END          AS grp_txn_id,
            CASE WHEN p_lots = 'Y' THEN MIN(o.trade_date) END         AS lot_trade_date,
            SUM(o.open_units)                                         AS units,
            SUM(ROUND(o.net_amount       * o.open_units / o.lot_units, 2)) AS cost_foreign,
            SUM(ROUND(o.net_amount_local * o.open_units / o.lot_units, 2)) AS cost_local
        FROM open_lots o
        WHERE o.open_units > 0
        GROUP BY
            o.fund_id,
            o.security_id,
            CASE WHEN p_lots = 'Y' THEN o.transaction_id END
    )

    SELECT
        CASE WHEN p_entity_id IS NOT NULL THEN 'ENTITY' ELSE 'GROUP' END AS scope_type,
        COALESCE(p_entity_id, p_group_id)                                AS scope_id,
        e.entity_id,
        e.entity_name,
        e.currency::text                                                 AS entity_currency,
        s.security_id,
        s.identifier,
        s.security_name,
        s.security_type,
        s.currency::text                                                 AS security_currency,
        a.grp_txn_id                                                     AS transaction_id,
        a.lot_trade_date                                                 AS trade_date,
        a.units::numeric(18,4),
        a.cost_foreign::numeric(18,2),
        ROUND(a.units * mp.price, 2)::numeric(18,2)                      AS market_value_foreign,
        a.cost_local::numeric(18,2),
        ROUND(a.units * mp.price * fx.fx_rate, 2)::numeric(18,2)         AS market_value_local,
        fx.fx_rate::numeric(18,8),
        ROUND(a.cost_local / NULLIF(a.cost_foreign, 0), 8)::numeric(18,8) AS fx_rate_cost,
        ROUND(a.cost_foreign / NULLIF(a.units, 0), 6)::numeric(18,6)     AS cost_per_unit_foreign,
        mp.price::numeric(18,4)                                          AS price_per_unit_foreign
    FROM agg a
    JOIN public.entities   e ON e.entity_id   = a.fund_id
    JOIN public.securities s ON s.security_id = a.security_id
    LEFT JOIN LATERAL
    (
        SELECT pr.price
        FROM public.prices pr
        WHERE pr.security_id = a.security_id
          AND pr.price_date <= p_as_of_date
        ORDER BY pr.price_date DESC
        LIMIT 1
    ) mp ON TRUE
    LEFT JOIN LATERAL
    (
        SELECT f.fx_rate
        FROM public.fx_rates f
        WHERE f.currency               = s.currency
          AND f.quote_against_currency = e.currency
          AND f.rate_date             < p_as_of_date
        ORDER BY f.rate_date DESC
        LIMIT 1
    ) fx ON TRUE
    ORDER BY e.entity_id, s.security_id, a.grp_txn_id NULLS FIRST;
END;
$$;

