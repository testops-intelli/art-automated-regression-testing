DROP TABLE IF EXISTS public.securities;

CREATE TABLE public.securities
(
    security_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_name     TEXT NOT NULL UNIQUE,
    security_type     TEXT NOT NULL,
    identifier_type   TEXT NOT NULL,
    identifier        TEXT NOT NULL,
    exchange_code     TEXT NOT NULL,
    currency          CHAR(3) NOT NULL
);


INSERT INTO public.securities
(
    security_name,
    security_type,
    identifier_type,
    identifier,
    exchange_code,
    currency
)
VALUES
    -- ============ AUD / ASX ============
    ('BHP Group Limited',                   'EQUITY', 'TICKER', 'BHP',   'ASX',    'AUD'),
    ('National Australia Bank Limited',     'EQUITY', 'TICKER', 'NAB',   'ASX',    'AUD'),
    ('Commonwealth Bank of Australia',      'EQUITY', 'TICKER', 'CBA',   'ASX',    'AUD'),
    ('Rio Tinto Limited',                   'EQUITY', 'TICKER', 'RIO',   'ASX',    'AUD'),
    ('Pilbara Minerals Limited',            'EQUITY', 'TICKER', 'PLS',   'ASX',    'AUD'),

    -- ============ USD / NASDAQ ============
    ('Tesla Inc',                           'EQUITY', 'TICKER', 'TSLA',  'NASDAQ', 'USD'),
    ('Netflix Inc',                         'EQUITY', 'TICKER', 'NFLX',  'NASDAQ', 'USD'),
    ('Microsoft Corporation',               'EQUITY', 'TICKER', 'MSFT',  'NASDAQ', 'USD'),
    ('Alphabet Inc Class A',                'EQUITY', 'TICKER', 'GOOGL', 'NASDAQ', 'USD'),
    ('NVIDIA Corporation',                  'EQUITY', 'TICKER', 'NVDA',  'NASDAQ', 'USD'),

    -- ============ GBP / LSE ============
    ('Shell plc',                           'EQUITY', 'TICKER', 'SHEL',  'LSE',    'GBP'),
    ('HSBC Holdings plc',                   'EQUITY', 'TICKER', 'HSBA',  'LSE',    'GBP'),
    ('AstraZeneca plc',                     'EQUITY', 'TICKER', 'AZN',   'LSE',    'GBP'),
    ('Unilever plc',                        'EQUITY', 'TICKER', 'ULVR',  'LSE',    'GBP'),
    ('BP plc',                              'EQUITY', 'TICKER', 'BP',    'LSE',    'GBP'),

    -- ============ EUR / AMS, XETR, EPA ============
    ('ASML Holding NV',                     'EQUITY', 'TICKER', 'ASML',  'AMS',    'EUR'),
    ('SAP SE',                              'EQUITY', 'TICKER', 'SAP',   'XETR',   'EUR'),
    ('LVMH Moet Hennessy Louis Vuitton SE', 'EQUITY', 'TICKER', 'MC',    'EPA',    'EUR'),
    ('Siemens AG',                          'EQUITY', 'TICKER', 'SIE',   'XETR',   'EUR'),
    ('Airbus SE',                           'EQUITY', 'TICKER', 'AIR',   'EPA',    'EUR'),

    -- ============ JPY / TSE ============
    ('Toyota Motor Corporation',            'EQUITY', 'TICKER', '7203',  'TSE',    'JPY'),
    ('Sony Group Corporation',              'EQUITY', 'TICKER', '6758',  'TSE',    'JPY'),
    ('SoftBank Group Corp',                 'EQUITY', 'TICKER', '9984',  'TSE',    'JPY'),
    ('Mitsubishi UFJ Financial Group Inc',  'EQUITY', 'TICKER', '8306',  'TSE',    'JPY'),
    ('Keyence Corporation',                 'EQUITY', 'TICKER', '6861',  'TSE',    'JPY');

INSERT INTO public.securities
(security_name, security_type, identifier_type, identifier, exchange_code, currency)
VALUES
    -- ============ AUD ============
    ('Australian Government Bond 3.25% 21-Apr-2029',        'BOND',   'ISIN', 'AU3TB0002297', 'OTC', 'AUD'),
    ('Westpac Banking Corp 4.75% 15-Aug-2028',              'BOND',   'ISIN', 'AU3CB0287654', 'OTC', 'AUD'),
    ('CBA Capital Notes BBSW3M+285bp Perpetual',            'HYBRID', 'ISIN', 'AU3FN0056735', 'ASX', 'AUD'),

    -- ============ USD ============
    ('US Treasury Note 4.125% 15-Nov-2032',                 'BOND',   'ISIN', 'US91282CJK07', 'OTC', 'USD'),
    ('JPMorgan Chase & Co 5.35% 01-Jun-2030',               'BOND',   'ISIN', 'US46625HAB02', 'OTC', 'USD'),
    ('Morgan Stanley FRN SOFR+120bp 15-Jul-2029',           'HYBRID', 'ISIN', 'US61747YEQ02', 'OTC', 'USD'),

    -- ============ GBP ============
    ('UK Gilt 4.25% 07-Dec-2032',                           'BOND',   'ISIN', 'GB00BM8Z2S05', 'OTC', 'GBP'),
    ('Barclays PLC 5.20% 12-May-2029',                      'BOND',   'ISIN', 'XS2478392017', 'OTC', 'GBP'),
    ('Lloyds Banking Group AT1 SONIA+340bp Perpetual',      'HYBRID', 'ISIN', 'XS2510448736', 'OTC', 'GBP'),

    -- ============ EUR ============
    ('German Federal Bund 2.60% 15-Aug-2034',               'BOND',   'ISIN', 'DE0001102614', 'OTC', 'EUR'),
    ('BNP Paribas SA 3.875% 20-Mar-2031',                   'BOND',   'ISIN', 'FR001400HG09', 'OTC', 'EUR'),
    ('Deutsche Bank AG Tier 2 EURIBOR3M+195bp 2032',        'HYBRID', 'ISIN', 'DE000DB9X404', 'OTC', 'EUR'),

    -- ============ JPY ============
    ('Japan Government Bond 0.80% 20-Sep-2033',             'BOND',   'ISIN', 'JP1201381389', 'OTC', 'JPY'),
    ('Sumitomo Mitsui Banking Corp 1.150% 18-Oct-2030',     'BOND',   'ISIN', 'JP345720AC02', 'OTC', 'JPY'),
    ('Nomura Holdings Sub FRN TONA+90bp 2031',              'HYBRID', 'ISIN', 'JP392610BD05', 'OTC', 'JPY');

	INSERT INTO public.securities
(security_name, security_type, identifier_type, identifier, exchange_code, currency)
VALUES
    -- ============ AUD / ASX ============
    ('BetaShares Australia 200 ETF',              'ETF', 'TICKER', 'A200', 'ASX',    'AUD'),
    ('Global X Physical Gold ETF',                'ETF', 'TICKER', 'GOLD', 'ASX',    'AUD'),

    -- ============ USD ============
    ('SPDR S&P 500 ETF Trust',                    'ETF', 'TICKER', 'SPY',  'ARCA',   'USD'),
    ('Invesco QQQ Trust Series 1',                'ETF', 'TICKER', 'QQQ',  'NASDAQ', 'USD'),

    -- ============ GBP / LSE ============
    ('iShares Core FTSE 100 UCITS ETF',           'ETF', 'TICKER', 'ISF',  'LSE',    'GBP'),
    ('Vanguard FTSE 100 UCITS ETF',               'ETF', 'TICKER', 'VUKE', 'LSE',    'GBP'),

    -- ============ EUR ============
    ('iShares Core DAX UCITS ETF',                'ETF', 'TICKER', 'EXS1', 'XETR',   'EUR'),
    ('Amundi CAC 40 UCITS ETF',                   'ETF', 'TICKER', 'C40',  'EPA',    'EUR'),

    -- ============ JPY / TSE ============
    ('NEXT FUNDS TOPIX Exchange Traded Fund',     'ETF', 'TICKER', '1306', 'TSE',    'JPY'),
    ('NEXT FUNDS Nikkei 225 Exchange Traded Fund','ETF', 'TICKER', '1321', 'TSE',    'JPY');

	INSERT INTO public.securities
(security_name, security_type, identifier_type, identifier, exchange_code, currency)
VALUES
    ('SPI 200 Index Future Sep-2026',           'FUTURE', 'TICKER', 'APU26',   'ASX',   'AUD'),
    ('E-mini S&P 500 Index Future Sep-2026',    'FUTURE', 'TICKER', 'ESU26',   'CME',   'USD'),
    ('FTSE 100 Index Future Sep-2026',          'FUTURE', 'TICKER', 'ZU26',    'ICE',   'GBP'),
    ('EURO STOXX 50 Index Future Sep-2026',     'FUTURE', 'TICKER', 'FESXU26', 'EUREX', 'EUR'),
    ('Nikkei 225 Index Future Sep-2026',        'FUTURE', 'TICKER', 'NKU26',   'OSE',   'JPY');

	INSERT INTO public.securities
(security_name, security_type, identifier_type, identifier, exchange_code, currency)
VALUES
    ('BHP Group Ltd Call 46.00 18-Sep-2026',      'OPTION', 'TICKER', 'BHPQP6',              'ASX',  'AUD'),
    ('Tesla Inc Call 450.00 18-Dec-2026',         'OPTION', 'TICKER', 'TSLA261218C00450000', 'OPRA', 'USD'),
    ('AstraZeneca plc Put 110 18-Sep-2026',       'OPTION', 'TICKER', 'AZNU6P110',           'LSE',  'GBP'),
    ('ASML Holding NV Call 900.00 19-Mar-2027',   'OPTION', 'TICKER', 'ASMLH7C900',          'AMS',  'EUR'),
    ('Toyota Motor Corp Put 2800 18-Dec-2026',    'OPTION', 'TICKER', '7203Z6P2800',         'OSE',  'JPY');
