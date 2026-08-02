DROP FUNCTION IF EXISTS public.pnl(integer, date, date);

CREATE OR REPLACE FUNCTION public.pnl
(
    p_entity_id   integer,
    p_start_date  date,
    p_end_date    date
)
RETURNS TABLE
(
    entity_id           integer,
    entity_name         text,
    entity_currency     text,
    security_id         integer,
    identifier          text,
    security_name       text,
    security_type       text,
    security_currency   text,
    unrealised          numeric(18,2),
    realised            numeric(18,2),
    income              numeric(18,2),
    total_pnl           numeric(18,2),
    cost_base_invested  numeric(18,2),
    pct_return          numeric(18,6)
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_entity_id IS NULL THEN
        RAISE EXCEPTION 'p_entity_id is required';
    END IF;

    IF p_start_date IS NULL OR p_end_date IS NULL THEN
        RAISE EXCEPTION 'p_start_date and p_end_date are required';
    END IF;

    IF p_end_date < p_start_date THEN
        RAISE EXCEPTION 'p_end_date must be >= p_start_date';
    END IF;

    RETURN QUERY
    WITH ent AS
    (
        SELECT e.entity_id, e.entity_name, e.currency::text AS currency
        FROM public.entities e
        WHERE e.entity_id = p_entity_id
    ),

    -- full history to end_date: FIFO position depends on everything
    -- that came before, not just the reporting window
    txn AS
    (
        SELECT t.*
        FROM public.transactions t
        WHERE t.fund_id     = p_entity_id
          AND t.trade_date <= p_end_date
    ),

    buys AS
    (
        SELECT
            t.transaction_id, t.security_id, t.trade_date, t.units, t.net_amount_local,
            COALESCE(SUM(t.units) OVER (PARTITION BY t.security_id
                                        ORDER BY t.trade_date, t.transaction_id
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS b_start
        FROM txn t
        WHERE t.transaction_type = 'BUY'
    ),

    sells AS
    (
        SELECT
            t.transaction_id, t.security_id, t.trade_date, t.units, t.net_amount_local,
            COALESCE(SUM(t.units) OVER (PARTITION BY t.security_id
                                        ORDER BY t.trade_date, t.transaction_id
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS s_start
        FROM txn t
        WHERE t.transaction_type = 'SELL'
    ),

    sold_to_end AS
    (
        SELECT s.security_id, SUM(s.units) AS u
        FROM sells s GROUP BY s.security_id
    ),

    -- FIFO by interval overlap: a lot occupies [b_start, b_start+units)
    -- on the cumulative buy axis, a sell occupies [s_start, s_start+units)
    -- on the cumulative sell axis. The overlap is the matched quantity.
    matched AS
    (
        SELECT
            s.security_id,
            s.trade_date                        AS sell_date,
            LEAST(b.b_start + b.units, s.s_start + s.units)
              - GREATEST(b.b_start, s.s_start)  AS qty,
            s.net_amount_local / s.units        AS proceeds_pu,
            b.net_amount_local / b.units        AS cost_pu
        FROM sells s
        JOIN buys  b ON b.security_id = s.security_id
        WHERE LEAST(b.b_start + b.units, s.s_start + s.units)
                - GREATEST(b.b_start, s.s_start) > 0
    ),

    realised AS
    (
        SELECT m.security_id,
               SUM(m.qty * (m.proceeds_pu - m.cost_pu)) AS realised
        FROM matched m
        WHERE m.sell_date BETWEEN p_start_date AND p_end_date
        GROUP BY m.security_id
    ),

    open_end AS
    (
        SELECT
            b.security_id,
            b.trade_date,
            b.net_amount_local / b.units AS cost_pu,
            GREATEST(0, LEAST(b.units,
                              b.b_start + b.units - COALESCE(se.u, 0))) AS open_units
        FROM buys b
        LEFT JOIN sold_to_end se ON se.security_id = b.security_id
    ),

    -- period-start and period-end marks, in fund currency
    marks AS
    (
        SELECT
            s.security_id,
            ps.price * COALESCE(fxs.fx_rate, 1) AS ref_pu_start,
            pe.price * COALESCE(fxe.fx_rate, 1) AS value_pu_end,
            pe.price                            AS price_end_foreign
        FROM public.securities s
        CROSS JOIN ent e
        LEFT JOIN LATERAL (SELECT p.price FROM public.prices p
                            WHERE p.security_id = s.security_id
                              AND p.price_date <= p_start_date
                            ORDER BY p.price_date DESC LIMIT 1) ps ON TRUE
        LEFT JOIN LATERAL (SELECT p.price FROM public.prices p
                            WHERE p.security_id = s.security_id
                              AND p.price_date <= p_end_date
                            ORDER BY p.price_date DESC LIMIT 1) pe ON TRUE
        LEFT JOIN LATERAL (SELECT f.fx_rate FROM public.fx_rates f
                            WHERE f.currency = s.currency
                              AND f.quote_against_currency = e.currency
                              AND f.rate_date <= p_start_date
                            ORDER BY f.rate_date DESC LIMIT 1) fxs ON TRUE
        LEFT JOIN LATERAL (SELECT f.fx_rate FROM public.fx_rates f
                            WHERE f.currency = s.currency
                              AND f.quote_against_currency = e.currency
                              AND f.rate_date <= p_end_date
                            ORDER BY f.rate_date DESC LIMIT 1) fxe ON TRUE
    ),

    -- lots held from before the window mark off the opening price;
    -- lots opened inside it mark off their own cost
    unreal AS
    (
        SELECT
            o.security_id,
            SUM(o.open_units *
                (m.value_pu_end
                 - CASE WHEN o.trade_date < p_start_date
                        THEN COALESCE(m.ref_pu_start, o.cost_pu)
                        ELSE o.cost_pu END)) AS unrealised
        FROM open_end o
        JOIN marks m ON m.security_id = o.security_id
        WHERE o.open_units > 0
        GROUP BY o.security_id
    ),

    -- entitled if the position was held as at pay_date - 1, trade-date basis
    income_calc AS
    (
        SELECT i.security_id,
               SUM(h.units * i.amount_per_unit * COALESCE(fx.fx_rate, 1)) AS income
        FROM public.income i
        JOIN public.securities s ON s.security_id = i.security_id
        CROSS JOIN ent e
        CROSS JOIN LATERAL
        (
            SELECT COALESCE(SUM(CASE WHEN t.transaction_type = 'BUY'
                                     THEN t.units ELSE -t.units END), 0) AS units
            FROM txn t
            WHERE t.security_id = i.security_id
              AND t.trade_date <= i.pay_date
        ) h
        LEFT JOIN LATERAL
        (
            SELECT f.fx_rate FROM public.fx_rates f
            WHERE f.currency = s.currency
              AND f.quote_against_currency = e.currency
              AND f.rate_date <= i.pay_date
            ORDER BY f.rate_date DESC LIMIT 1
        ) fx ON TRUE
        WHERE i.pay_date BETWEEN p_start_date AND p_end_date
          AND h.units > 0
        GROUP BY i.security_id
    ),

    invested AS
    (
        SELECT t.security_id, SUM(t.net_amount_local) AS cost_base
        FROM txn t
        WHERE t.transaction_type = 'BUY'
          AND t.trade_date BETWEEN p_start_date AND p_end_date
        GROUP BY t.security_id
    ),

    universe AS
    (
        SELECT u.security_id FROM unreal u
        UNION SELECT r.security_id FROM realised r
        UNION SELECT c.security_id FROM income_calc c
    )

    SELECT
        e.entity_id,
        e.entity_name,
        e.currency,
        s.security_id,
        s.identifier,
        s.security_name,
        s.security_type,
        s.currency::text,
        ROUND(COALESCE(u.unrealised, 0), 2)::numeric(18,2),
        ROUND(COALESCE(r.realised,   0), 2)::numeric(18,2),
        ROUND(COALESCE(c.income,     0), 2)::numeric(18,2),
        ROUND(COALESCE(u.unrealised,0) + COALESCE(r.realised,0)
              + COALESCE(c.income,0), 2)::numeric(18,2),
        ROUND(COALESCE(i.cost_base, 0), 2)::numeric(18,2),
        ROUND(
            (COALESCE(u.unrealised,0) + COALESCE(r.realised,0) + COALESCE(c.income,0))
            / NULLIF(i.cost_base, 0)
        , 6)::numeric(18,6)
    FROM universe un
    JOIN public.securities s ON s.security_id = un.security_id
    CROSS JOIN ent e
    LEFT JOIN unreal      u ON u.security_id = un.security_id
    LEFT JOIN realised    r ON r.security_id = un.security_id
    LEFT JOIN income_calc c ON c.security_id = un.security_id
    LEFT JOIN invested    i ON i.security_id = un.security_id
    WHERE COALESCE(u.unrealised,0) <> 0
       OR COALESCE(r.realised,0)   <> 0
       OR COALESCE(c.income,0)     <> 0
    ORDER BY s.security_id;
END;
$$;
