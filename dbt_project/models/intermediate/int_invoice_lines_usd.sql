/*
    Currency normalization: every invoice line converted to USD.

    Translated at the rate on the invoice's issued date, not today's rate and not
    a period-average. This is the accounting convention (translate at the
    transaction date), and it has a property the alternatives lack: a closed
    month's revenue never moves again. Using a current rate would silently
    restate every historical month each time FX moved, so last March's ARR would
    be a different number depending on when you asked — which is precisely the
    "three teams, three numbers" problem this platform exists to end.

    The join is on issued_date, which is derived from issued_at_utc — i.e. after
    the timezone correction. Translating on the uncorrected date would use the
    wrong day's rate for the 9,352 lines that the IST shift misdates.
*/

with invoice_lines as (

    select * from {{ ref('stg_invoices') }}

),

fx as (

    select * from {{ ref('stg_fx_rates') }}

),

converted as (

    select
        invoice_lines.*,

        fx.rate_to_usd,

        -- amount_local was quoted in the customer's currency; rate_to_usd is
        -- units-of-local-per-USD, so this divides rather than multiplies. Getting
        -- that inverted is invisible for USD (rate 1.0) and catastrophic for JPY
        -- (rate ~151) — the kind of bug that looks fine in every US-customer spot
        -- check. tests/assert_usd_conversion_is_identity_for_usd.sql pins the
        -- trivial half; the accepted_range on rate_to_usd guards the rest.
        round(invoice_lines.amount_local / fx.rate_to_usd, 2) as amount_usd

    from invoice_lines
    left join fx
        on
            invoice_lines.currency_code = fx.currency_code
            and invoice_lines.issued_date = fx.rate_date

)

select * from converted
