DROP TABLE IF EXISTS public.income;

CREATE TABLE public.income
(
    income_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id      INTEGER NOT NULL
                     REFERENCES public.securities(security_id),
    income_type      TEXT NOT NULL
                     CHECK (income_type IN ('DIVIDEND','INTEREST')),
    amount_per_unit  NUMERIC(18,6) NOT NULL CHECK (amount_per_unit > 0),
    pay_date         DATE NOT NULL,

    CONSTRAINT uq_income UNIQUE (security_id, pay_date)
);

CREATE INDEX ix_income_pay_date ON public.income (pay_date);

INSERT INTO public.income (security_id, income_type, amount_per_unit, pay_date)
WITH pay_dates (pay_date) AS
(
    VALUES (DATE '2025-03-15'), (DATE '2025-06-15'), (DATE '2025-09-15'),
           (DATE '2025-12-15'), (DATE '2026-03-15'), (DATE '2026-06-15')
),
base AS
(
    SELECT
        s.security_id,
        s.security_type,
        (SELECT p.price FROM public.prices p
          WHERE p.security_id = s.security_id
          ORDER BY p.price_date LIMIT 1)                                   AS ref_price,
        ('x' || substr(md5(s.security_id::text || ':yield'), 1, 7))::bit(28)::int AS h
    FROM public.securities s
    WHERE s.security_type IN ('EQUITY','ETF','BOND','HYBRID')
)
SELECT
    b.security_id,
    CASE WHEN b.security_type IN ('EQUITY','ETF') THEN 'DIVIDEND' ELSE 'INTEREST' END,
    ROUND(b.ref_price * y.annual_yield / y.freq, 6),
    pd.pay_date
FROM base b
CROSS JOIN LATERAL
(
    SELECT
        CASE b.security_type
            WHEN 'EQUITY' THEN 0.015 + (b.h % 30)::numeric / 1000
            WHEN 'ETF'    THEN 0.020 + (b.h % 15)::numeric / 1000
            WHEN 'BOND'   THEN 0.030 + (b.h % 20)::numeric / 1000
            ELSE               0.050 + (b.h % 25)::numeric / 1000
        END                                                       AS annual_yield,
        CASE WHEN b.security_type IN ('EQUITY','ETF') THEN 4 ELSE 2 END AS freq
) y
CROSS JOIN pay_dates pd
WHERE b.security_type IN ('EQUITY','ETF')
   OR EXTRACT(MONTH FROM pd.pay_date) IN (6,12);
