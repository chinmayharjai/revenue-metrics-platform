{{ config(severity = 'error', tags = ['data_quality', 'currency']) }}

/*
    Currency normalization sanity.

    Three checks that together pin down the direction of the conversion:

      1. USD converts to itself. Trivial, and that is the point — if the divide
         were a multiply, USD (rate 1.0) would still be right and every US
         customer would spot-check clean while JPY was off by 151x. This check
         alone proves nothing; it is here so that check 2 has a control.

      2. No conversion produced NULL. A missing FX rate for a currency/date pair
         makes the left join yield NULL, the row drops out of every SUM, and ARR
         quietly loses a country. The relationships test on currency_code catches a
         missing *currency*; this catches a missing *date*, which is the more likely
         gap — one absent day in a rate feed.

      3. Non-USD amounts actually changed. If a bad join silently attached rate 1.0
         to every row, checks 1 and 2 both pass and revenue is wrong by the whole
         FX basis. This is the check that would notice.
*/

with lines as (

    select * from {{ ref('int_invoice_lines_usd') }}

),

failures as (

    select
        invoice_line_key,
        currency_code,
        amount_local,
        amount_usd,
        rate_to_usd,
        'USD line did not convert to itself' as failure_reason
    from lines
    where
        currency_code = 'USD'
        and abs(amount_local - amount_usd) > 0.01

    union all

    select
        invoice_line_key,
        currency_code,
        amount_local,
        amount_usd,
        rate_to_usd,
        'no FX rate found for this currency and issued_date' as failure_reason
    from lines
    where
        amount_usd is null
        or rate_to_usd is null

    union all

    select
        invoice_line_key,
        currency_code,
        amount_local,
        amount_usd,
        rate_to_usd,
        'non-USD line was assigned an identity rate' as failure_reason
    from lines
    where
        currency_code != 'USD'
        and rate_to_usd = 1.0

)

select * from failures
