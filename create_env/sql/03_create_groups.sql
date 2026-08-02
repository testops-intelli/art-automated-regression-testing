DROP TABLE IF EXISTS public.groups;

CREATE TABLE public.groups
(
    group_id    INTEGER NOT NULL,
    entity_id   INTEGER NOT NULL
                REFERENCES public.entities(entity_id),

    CONSTRAINT pk_groups PRIMARY KEY (group_id, entity_id)
);

INSERT INTO public.groups (group_id, entity_id)
VALUES
    -- Group 1 — APAC (2 entities, AUD + JPY)
    (1, 1),   -- Southern Cross Superannuation Fund   AUD
    (1, 3),   -- Sakura Japan Opportunities Fund      JPY

    -- Group 2 — EMEA (3 entities, GBP + EUR + USD)
    (2, 2),   -- Meridian Global Equity Fund          USD
    (2, 4),   -- Thames Valley Property Trust         GBP
    (2, 5),   -- Ardenne European Credit Trust        EUR

    -- Group 3 — Trusts & Managed (4 entities)
    (3, 1),   -- Southern Cross Superannuation Fund   AUD
    (3, 2),   -- Meridian Global Equity Fund          USD
    (3, 4),   -- Thames Valley Property Trust         GBP
    (3, 5);   -- Ardenne European Credit Trust        EUR

