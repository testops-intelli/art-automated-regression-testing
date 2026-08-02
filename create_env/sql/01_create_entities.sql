DROP TABLE IF EXISTS public.entities;

CREATE TABLE public.entities
(
    entity_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_name   TEXT NOT NULL UNIQUE,
    entity_type   TEXT NOT NULL,
    country       CHAR(2) NOT NULL,
    currency      CHAR(3) NOT NULL
);

INSERT INTO public.entities
(
    entity_name,
    entity_type,
    country,
    currency
)
VALUES
    ('Southern Cross Superannuation Fund', 'SUPER FUND', 'AU', 'AUD'),
    ('Meridian Global Equity Fund',        'FUND',       'US', 'USD'),
    ('Sakura Japan Opportunities Fund',    'FUND',       'JP', 'JPY'),
    ('Thames Valley Property Trust',       'TRUST',      'GB', 'GBP'),
    ('Ardenne European Credit Trust',      'TRUST',      'LU', 'EUR');


