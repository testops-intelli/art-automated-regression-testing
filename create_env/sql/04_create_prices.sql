DROP TABLE IF EXISTS public.prices;

CREATE TABLE public.prices
(
    security_id   INTEGER NOT NULL
                  REFERENCES public.securities(security_id),
    price_date    DATE    NOT NULL,
    price         NUMERIC(18,4) NOT NULL,

    CONSTRAINT pk_prices PRIMARY KEY (security_id, price_date)
);

CREATE INDEX ix_prices_date ON public.prices (price_date);

TRUNCATE TABLE public.prices;

INSERT INTO public.prices (security_id, price_date, price)
WITH month_ends AS
(
    SELECT
        (date_trunc('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date AS price_date,
        (ROW_NUMBER() OVER (ORDER BY d) - 1)                                   AS m_idx
    FROM generate_series(DATE '2025-01-01', DATE '2026-07-01', INTERVAL '1 month') AS d
),
seed (identifier, base_price, trend, vol) AS
(
    VALUES
        -- ---------- AUD equities ----------
        ('BHP'::TEXT,   45.20::NUMERIC,  0.004::NUMERIC, 0.055::NUMERIC),
        ('NAB',         38.60,           0.006,          0.045),
        ('CBA',        182.40,           0.007,          0.040),
        ('RIO',        121.80,           0.003,          0.060),
        ('PLS',          2.45,          -0.008,          0.110),

        -- ---------- USD equities ----------
        ('TSLA',       348.00,           0.010,          0.120),
        ('NFLX',       905.00,           0.009,          0.070),
        ('MSFT',       452.00,           0.007,          0.050),
        ('GOOGL',      191.50,           0.008,          0.060),
        ('NVDA',       142.30,           0.014,          0.130),

        -- ---------- GBP equities (quoted in pence) ----------
        ('SHEL',        28.10,           0.004,          0.050),
        ('HSBA',         9.05,           0.006,          0.045),
        ('AZN',        112.40,           0.005,          0.045),
        ('ULVR',        46.20,           0.002,          0.035),
        ('BP',         4.0250,          -0.003,          0.065),

        -- ---------- EUR equities ----------
        ('ASML',       702.00,           0.011,          0.090),
        ('SAP',        231.50,           0.008,          0.050),
        ('MC',         598.00,          -0.004,          0.070),
        ('SIE',        188.40,           0.006,          0.050),
        ('AIR',        162.80,           0.005,          0.055),

        -- ---------- JPY equities ----------
        ('7203',      2840.00,           0.005,          0.050),
        ('6758',      3010.00,           0.007,          0.060),
        ('9984',      9150.00,           0.009,          0.110),
        ('8306',      1795.00,           0.008,          0.055),
        ('6861',     60200.00,           0.003,          0.060),

        -- ---------- Bonds & hybrids (% of par) ----------
        ('AU3TB0002297', 99.40,          0.001,          0.012),
        ('AU3CB0287654',100.85,          0.000,          0.010),
        ('AU3FN0056735',101.30,          0.001,          0.014),
        ('US91282CJK07', 97.60,          0.002,          0.015),
        ('US46625HAB02',101.95,          0.000,          0.011),
        ('US61747YEQ02',100.20,          0.000,          0.009),
        ('GB00BM8Z2S05', 96.80,          0.002,          0.016),
        ('XS2478392017',101.40,          0.001,          0.012),
        ('XS2510448736', 99.70,          0.001,          0.018),
        ('DE0001102614', 98.30,          0.001,          0.013),
        ('FR001400HG09',100.60,          0.000,          0.011),
        ('DE000DB9X404', 99.10,          0.001,          0.015),
        ('JP1201381389', 95.20,          0.001,          0.010),
        ('JP345720AC02', 98.75,          0.000,          0.009),
        ('JP392610BD05',100.05,          0.000,          0.012),

        -- ---------- ETFs ----------
        ('A200',       142.30,           0.005,          0.040),
        ('GOLD',        41.80,           0.009,          0.055),
        ('SPY',        602.50,           0.007,          0.045),
        ('QQQ',        521.40,           0.009,          0.060),
        ('ISF',          8.32,           0.004,          0.040),
        ('VUKE',        38.10,           0.004,          0.040),
        ('EXS1',       181.60,           0.006,          0.050),
        ('C40',         85.40,           0.004,          0.045),
        ('1306',      2905.00,           0.005,          0.045),
        ('1321',     40150.00,           0.006,          0.050),

        -- ---------- Futures (index level) ----------
        ('APU26',     8620.00,           0.004,          0.045),
        ('ESU26',     6035.00,           0.007,          0.050),
        ('ZU26',      8340.00,           0.004,          0.042),
        ('FESXU26',   5410.00,           0.005,          0.050),
        ('NKU26',    40200.00,           0.006,          0.055),

        -- ---------- Options (premium, decays toward expiry) ----------
        ('BHPQP6',                2.65,  -0.020,         0.260),
        ('TSLA261218C00450000',  34.80,  -0.015,         0.300),
        ('AZNU6P110',             4.52,  -0.018,         0.250),
        ('ASMLH7C900',           51.40,  -0.012,         0.280),
        ('7203Z6P2800',         118.50,  -0.016,         0.270)
)
SELECT
    s.security_id,
    m.price_date,
    ROUND(
        (
            sd.base_price::DOUBLE PRECISION
            * (
                  1.0
                + sd.trend::DOUBLE PRECISION * m.m_idx::DOUBLE PRECISION
                + sd.vol::DOUBLE PRECISION
                  * SIN(m.m_idx::DOUBLE PRECISION * 0.7 + s.security_id::DOUBLE PRECISION)
              )
        )::NUMERIC
    , 4) AS price
FROM seed sd
JOIN public.securities s
  ON s.identifier = sd.identifier
CROSS JOIN month_ends m;


