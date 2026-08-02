DROP FUNCTION IF EXISTS public.transactions_listing(integer, integer, date, date, char(1), integer);

CREATE OR REPLACE FUNCTION public.transactions_listing
(
    p_fund_id       integer,
    p_group_id      integer,
    p_start_date    date,
    p_end_date      date,
    p_settled       char(1),
    p_active_flag   integer
)
RETURNS TABLE
(
    transaction_id      bigint,
    scope_type          text,
    scope_id            integer,
    entity_id           integer,
    entity_name         text,
    entity_type         text,
    fund_currency       text,
    security_id         integer,
    identifier          text,
    security_name       text,
    security_type       text,
    exchange_code       text,
    security_currency   text,
    trade_date          date,
    settlement_date     date,
    settled_flag        integer,
    transaction_type    text,
    active_flag         integer,
    units               numeric(18,4),
    price               numeric(18,4),
    gross_amount        numeric(18,2),
    fees                numeric(18,2),
    net_amount          numeric(18,2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- ---------- param validation ----------
    IF (p_fund_id IS NULL AND p_group_id IS NULL)
       OR (p_fund_id IS NOT NULL AND p_group_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Exactly one of p_fund_id or p_group_id must be supplied';
    END IF;

    IF p_start_date IS NULL OR p_end_date IS NULL THEN
        RAISE EXCEPTION 'p_start_date and p_end_date are required';
    END IF;

    IF p_end_date < p_start_date THEN
        RAISE EXCEPTION 'p_end_date must be >= p_start_date';
    END IF;

    IF p_settled IS NULL OR p_settled NOT IN ('Y','N') THEN
        RAISE EXCEPTION 'p_settled must be Y or N';
    END IF;

    IF p_active_flag IS NOT NULL AND p_active_flag NOT IN (0,1) THEN
        RAISE EXCEPTION 'p_active_flag must be 0, 1 or NULL';
    END IF;

    -- ---------- report ----------
    RETURN QUERY
    SELECT
        t.transaction_id,
        CASE WHEN p_fund_id IS NOT NULL THEN 'FUND' ELSE 'GROUP' END        AS scope_type,
        COALESCE(p_fund_id, p_group_id)                                     AS scope_id,
        e.entity_id,
        e.entity_name,
        e.entity_type,
        e.currency::text                                                    AS fund_currency,
        s.security_id,
        s.identifier,
        s.security_name,
        s.security_type,
        s.exchange_code,
        s.currency::text                                                    AS security_currency,
        t.trade_date,
        t.settlement_date,
        CASE WHEN t.settlement_date <= p_end_date THEN 1 ELSE 0 END         AS settled_flag,
        t.transaction_type,
        t.active_flag,
        t.units,
        t.price,
        t.gross_amount,
        t.fees,
        t.net_amount
    FROM public.transactions t
    JOIN public.entities   e ON e.entity_id   = t.fund_id
    JOIN public.securities s ON s.security_id = t.security_id
    WHERE t.trade_date BETWEEN p_start_date AND p_end_date
      AND (
            (p_fund_id IS NOT NULL AND t.fund_id = p_fund_id)
            OR
            (p_group_id IS NOT NULL AND t.fund_id IN (
                 SELECT g.entity_id
                 FROM public.groups g
                 WHERE g.group_id = p_group_id
             ))
          )
      AND (p_settled = 'N' OR t.settlement_date <= p_end_date)
      AND (p_active_flag IS NULL OR t.active_flag = p_active_flag)
    ORDER BY t.transaction_id;
END;
$$;
