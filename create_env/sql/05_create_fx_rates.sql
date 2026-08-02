DROP TABLE IF EXISTS public.fx_rates;

CREATE TABLE public.fx_rates
(
    currency                 CHAR(3) NOT NULL,
    quote_against_currency   CHAR(3) NOT NULL,
    rate_date                DATE    NOT NULL,
    quotation_type           TEXT    NOT NULL
                             CHECK (quotation_type IN ('PRICE','QUANTITY')),
    fx_rate                  NUMERIC(18,8) NOT NULL CHECK (fx_rate > 0),

    CONSTRAINT pk_fx_rates
        PRIMARY KEY (currency, quote_against_currency, rate_date)
);

CREATE INDEX ix_fx_rates_date ON public.fx_rates (rate_date);

TRUNCATE TABLE public.fx_rates;

INSERT INTO public.fx_rates
(currency, quote_against_currency, rate_date, quotation_type, fx_rate)
WITH month_ends AS
(
    SELECT
        (date_trunc('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date AS rate_date,
        (ROW_NUMBER() OVER (ORDER BY d) - 1)                                   AS m_idx
    FROM generate_series(DATE '2025-01-01', DATE '2026-07-01', INTERVAL '1 month') AS d
),
ccy (currency, usd_base, trend, vol, seed) AS
(
    VALUES
        ('AUD'::TEXT, 0.660000::NUMERIC, -0.002::NUMERIC, 0.030::NUMERIC, 1.0::NUMERIC),
        ('USD',       1.000000,           0.000,          0.000,          0.0),
        ('GBP',       1.270000,           0.001,          0.025,          2.0),
        ('EUR',       1.080000,           0.001,          0.028,          3.0),
        ('JPY',       0.006700,           0.003,          0.035,          4.0)
),
usd_curve AS
(
    SELECT
        c.currency,
        m.rate_date,
        c.usd_base::DOUBLE PRECISION
        * (
              1.0
            + c.trend::DOUBLE PRECISION * m.m_idx::DOUBLE PRECISION
            + c.vol::DOUBLE PRECISION
              * SIN(m.m_idx::DOUBLE PRECISION * 0.55 + c.seed::DOUBLE PRECISION)
          ) AS usd_per_unit
    FROM ccy c
    CROSS JOIN month_ends m
)
SELECT
    a.currency,
    b.currency,
    a.rate_date,
    'PRICE',
    ROUND((a.usd_per_unit / b.usd_per_unit)::NUMERIC, 8)
FROM usd_curve a
JOIN usd_curve b
  ON b.rate_date = a.rate_date;


