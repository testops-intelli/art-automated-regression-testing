DROP TABLE IF EXISTS public.transactions;

CREATE TABLE public.transactions
(
    transaction_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fund_id             INTEGER NOT NULL
                        REFERENCES public.entities(entity_id),
    security_id         INTEGER NOT NULL
                        REFERENCES public.securities(security_id),
    trade_date          DATE NOT NULL,
    settlement_date     DATE NOT NULL,
    transaction_type    TEXT NOT NULL CHECK (transaction_type IN ('BUY','SELL')),
    active_flag         INTEGER NOT NULL CHECK (active_flag IN (0,1)),
    units               NUMERIC(18,4) NOT NULL,
    price               NUMERIC(18,4) NOT NULL,
    gross_amount        NUMERIC(18,2) NOT NULL,
    fees                NUMERIC(18,2) NOT NULL,
    net_amount          NUMERIC(18,2) NOT NULL,
    fx_rate_trade       NUMERIC(18,8),
    gross_amount_local  NUMERIC(18,2),
    net_amount_local    NUMERIC(18,2),

    CONSTRAINT ck_transactions_settle CHECK (settlement_date >= trade_date)
);

CREATE INDEX ix_transactions_fund_date     ON public.transactions (fund_id, trade_date);
CREATE INDEX ix_transactions_security_date ON public.transactions (security_id, trade_date);
CREATE INDEX ix_transactions_trade_date    ON public.transactions (trade_date);

INSERT INTO public.transactions
(fund_id, security_id, trade_date, settlement_date,
 transaction_type, active_flag, units, price, gross_amount, fees, net_amount)
WITH all_bdays AS
(
    SELECT
        d::date                                  AS bday,
        ROW_NUMBER() OVER (ORDER BY d)           AS bd_seq,
        date_trunc('month', d)::date             AS month_start
    FROM generate_series(DATE '2025-01-01', DATE '2026-09-30', INTERVAL '1 day') AS d
    WHERE EXTRACT(ISODOW FROM d) < 6
),
months AS
(
    SELECT date_trunc('month', d)::date AS month_start
    FROM generate_series(DATE '2025-01-01', DATE '2026-07-01', INTERVAL '1 month') AS d
),
month_bdays AS
(
    SELECT
        b.month_start,
        b.bday,
        b.bd_seq,
        ROW_NUMBER() OVER (PARTITION BY b.month_start ORDER BY b.bday) AS bd_idx,
        COUNT(*)    OVER (PARTITION BY b.month_start)                  AS bd_count
    FROM all_bdays b
    JOIN months m ON m.month_start = b.month_start
),
ccy_scale (currency, notional) AS
(
    VALUES ('AUD'::TEXT,      250000::NUMERIC),
           ('USD',            250000),
           ('GBP',            200000),
           ('EUR',            200000),
           ('JPY',          30000000)
),
type_mult (security_type, mult) AS
(
    VALUES ('EQUITY'::TEXT, 1.00::NUMERIC),
           ('ETF',          1.00),
           ('BOND',         1.00),
           ('HYBRID',       1.00),
           ('FUTURE',       0.20),
           ('OPTION',       0.02)
),
candidates AS
(
    SELECT
        e.entity_id     AS fund_id,
        s.security_id,
        s.security_type,
        s.currency,
        m.month_start,
        ('x' || substr(md5(e.entity_id::text||':'||s.security_id::text||':'||m.month_start::text||':trade'), 1, 7))::bit(28)::int AS h_pick,
        ('x' || substr(md5(e.entity_id::text||':'||s.security_id::text||':'||m.month_start::text||':day'),   1, 7))::bit(28)::int AS h_day,
        ('x' || substr(md5(e.entity_id::text||':'||s.security_id::text||':'||m.month_start::text||':size'),  1, 7))::bit(28)::int AS h_size,
        ('x' || substr(md5(e.entity_id::text||':'||s.security_id::text||':'||m.month_start::text||':side'),  1, 7))::bit(28)::int AS h_side,
        ('x' || substr(md5(e.entity_id::text||':'||s.security_id::text||':'||m.month_start::text||':act'),   1, 7))::bit(28)::int AS h_act
    FROM public.entities   e
    CROSS JOIN public.securities s
    CROSS JOIN months      m
),
picked AS
(
    SELECT * FROM candidates WHERE h_pick % 100 < 45
),
dated AS
(
    SELECT
        p.*,
        mb.bday    AS trade_date,
        mb.bd_seq  AS trade_seq
    FROM picked p
    JOIN month_bdays mb
      ON mb.month_start = p.month_start
     AND mb.bd_idx      = 1 + (p.h_day % mb.bd_count)
),
priced AS
(
    SELECT
        d.*,
        ROUND(
            CASE
                WHEN pv.price_date IS NULL                 THEN nx.price
                WHEN nx.price_date IS NULL                 THEN pv.price
                WHEN nx.price_date = pv.price_date         THEN pv.price
                ELSE pv.price
                     + (nx.price - pv.price)
                       * (d.trade_date - pv.price_date)::NUMERIC
                       / (nx.price_date - pv.price_date)::NUMERIC
            END
        , 2) AS trade_price
    FROM dated d
    LEFT JOIN LATERAL
    (
        SELECT pr.price, pr.price_date
        FROM public.prices pr
        WHERE pr.security_id = d.security_id
          AND pr.price_date <= d.trade_date
        ORDER BY pr.price_date DESC
        LIMIT 1
    ) pv ON TRUE
    LEFT JOIN LATERAL
    (
        SELECT pr.price, pr.price_date
        FROM public.prices pr
        WHERE pr.security_id = d.security_id
          AND pr.price_date >= d.trade_date
        ORDER BY pr.price_date ASC
        LIMIT 1
    ) nx ON TRUE
),
sized AS
(
    SELECT
        p.*,
        GREATEST(1, ROUND(
            cs.notional * tm.mult
            * (0.50 + (p.h_size % 100)::NUMERIC / 100.0)
            / p.trade_price
        , 0)) AS units
    FROM priced p
    JOIN ccy_scale cs ON cs.currency      = p.currency
    JOIN type_mult tm ON tm.security_type = p.security_type
),
final AS
(
    SELECT
        s.fund_id,
        s.security_id,
        s.trade_date,
        sb.bday                                            AS settlement_date,
        CASE WHEN s.h_side % 100 < 65 THEN 'BUY' ELSE 'SELL' END AS transaction_type,
        CASE WHEN s.h_act  % 100 < 85 THEN 1     ELSE 0     END  AS active_flag,
        s.units,
        s.trade_price                                      AS price,
        ROUND(s.units * s.trade_price, 2)                  AS gross_amount
    FROM sized s
    JOIN all_bdays sb ON sb.bd_seq = s.trade_seq + 2
)
SELECT
    f.fund_id,
    f.security_id,
    f.trade_date,
    f.settlement_date,
    f.transaction_type,
    f.active_flag,
    f.units,
    f.price,
    f.gross_amount,
    ROUND(f.gross_amount * 0.01, 2)                        AS fees,
    CASE
        WHEN f.transaction_type = 'BUY'
            THEN ROUND(f.gross_amount + ROUND(f.gross_amount * 0.01, 2), 2)
        ELSE     ROUND(f.gross_amount - ROUND(f.gross_amount * 0.01, 2), 2)
    END                                                    AS net_amount
FROM final f;

-- =========================================================
-- 3. Normalise short positions
-- The generator is probabilistic, so a running balance can go
-- negative. FIFO requires cumulative SELL <= cumulative BUY at
-- every point in time, not merely in total. Walk each
-- (fund, security) in date order and flip any SELL that would
-- overdraw the balance.
-- =========================================================

WITH RECURSIVE ordered AS
(
    SELECT
        transaction_id, fund_id, security_id, transaction_type, units,
        ROW_NUMBER() OVER (PARTITION BY fund_id, security_id
                           ORDER BY trade_date, transaction_id) AS rn
    FROM public.transactions
),
walk AS
(
    SELECT o.transaction_id, o.fund_id, o.security_id, o.rn,
           'BUY'::text       AS new_type,
           o.units::numeric  AS balance
    FROM ordered o
    WHERE o.rn = 1

    UNION ALL

    SELECT o.transaction_id, o.fund_id, o.security_id, o.rn,
           CASE WHEN o.transaction_type = 'SELL' AND o.units <= w.balance
                THEN 'SELL' ELSE 'BUY' END,
           (CASE WHEN o.transaction_type = 'SELL' AND o.units <= w.balance
                 THEN w.balance - o.units ELSE w.balance + o.units END)::numeric
    FROM walk w
    JOIN ordered o
      ON o.fund_id     = w.fund_id
     AND o.security_id = w.security_id
     AND o.rn          = w.rn + 1
)
UPDATE public.transactions t
SET transaction_type = w.new_type,
    net_amount       = CASE WHEN w.new_type = 'BUY'
                            THEN t.gross_amount + t.fees
                            ELSE t.gross_amount - t.fees END
FROM walk w
WHERE t.transaction_id  = w.transaction_id
  AND t.transaction_type <> w.new_type;


-- =========================================================
-- 4. Stamp historical FX
-- Cost basis is translated at trade-date FX and frozen, so the
-- positions report never re-derives it. Linear interpolation
-- between month-end rates, matching how trade prices are
-- interpolated above.
-- =========================================================

UPDATE public.transactions t
SET fx_rate_trade      = x.rate,
    gross_amount_local = ROUND(t.gross_amount * x.rate, 2),
    net_amount_local   = ROUND(t.net_amount   * x.rate, 2)
FROM
(
    SELECT
        t2.transaction_id,
        CASE
            WHEN pv.rate_date IS NULL        THEN nx.fx_rate
            WHEN nx.rate_date IS NULL        THEN pv.fx_rate
            WHEN nx.rate_date = pv.rate_date THEN pv.fx_rate
            ELSE pv.fx_rate
                 + (nx.fx_rate - pv.fx_rate)
                   * (t2.trade_date - pv.rate_date)::numeric
                   / (nx.rate_date  - pv.rate_date)::numeric
        END AS rate
    FROM public.transactions t2
    JOIN public.securities s ON s.security_id = t2.security_id
    JOIN public.entities   e ON e.entity_id   = t2.fund_id
    LEFT JOIN LATERAL
    (
        SELECT f.fx_rate, f.rate_date
        FROM public.fx_rates f
        WHERE f.currency               = s.currency
          AND f.quote_against_currency = e.currency
          AND f.rate_date             <= t2.trade_date
        ORDER BY f.rate_date DESC LIMIT 1
    ) pv ON TRUE
    LEFT JOIN LATERAL
    (
        SELECT f.fx_rate, f.rate_date
        FROM public.fx_rates f
        WHERE f.currency               = s.currency
          AND f.quote_against_currency = e.currency
          AND f.rate_date             >= t2.trade_date
        ORDER BY f.rate_date ASC LIMIT 1
    ) nx ON TRUE
) x
WHERE x.transaction_id = t.transaction_id;

ALTER TABLE public.transactions
    ALTER COLUMN fx_rate_trade      SET NOT NULL,
    ALTER COLUMN gross_amount_local SET NOT NULL,
    ALTER COLUMN net_amount_local   SET NOT NULL;

