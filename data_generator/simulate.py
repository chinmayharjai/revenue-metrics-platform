"""Generate a realistic, deliberately-flawed SaaS billing dataset.

Emits CSVs to data/raw/ that mimic what lands in a warehouse RAW schema when you
tap a billing system (Stripe/Zuora-shaped), a CRM, and an FX feed:

    customers.csv       one row per account
    employees.csv       sales org, self-referencing (fuels the recursive-CTE showcase)
    plans.csv           product catalogue
    subscriptions.csv   one row per subscription *spell* (a period on one plan/seat count)
    invoices.csv        one row per invoice *line item*
    fx_rates.csv        daily rate to USD per currency

Subscriptions bill on their anniversary date, not calendar month ends. That is
what real SaaS billing does, and it means a customer-month revenue grain cannot
be reached by a GROUP BY alone -- the transform layer has to allocate each
billing period across the calendar months it straddles.

The data is intentionally dirty. Every defect is injected on purpose, counted,
and written to data/raw/_manifest.json so the dbt tests downstream can be shown
catching a known quantity rather than an anecdote. See the README section
"Injected data problems" for the catalogue.

Usage:
    python data_generator/simulate.py                  # defaults match the PRD
    python data_generator/simulate.py --seed 7 --customers 500 --out data/sample
"""

from __future__ import annotations

import argparse
import json
from datetime import date, datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

# 24-month window ending at a fixed anchor so runs are reproducible and the
# "as of" date in the marts never drifts with the wall clock.
ANCHOR_END = date(2026, 6, 30)

# Approximate mid-2024 rates; the daily series random-walks around these.
CURRENCY_BASE_RATES = {
    "USD": 1.00,
    "EUR": 0.92,
    "GBP": 0.79,
    "INR": 83.20,
    "AUD": 1.52,
    "CAD": 1.36,
    "SGD": 1.34,
    "JPY": 151.00,
}

# (country, currency, weight) -- US-heavy, as a US-founded SaaS would be.
COUNTRIES = [
    ("US", "USD", 0.42),
    ("GB", "GBP", 0.11),
    ("DE", "EUR", 0.09),
    ("FR", "EUR", 0.06),
    ("IN", "INR", 0.12),
    ("AU", "AUD", 0.06),
    ("CA", "CAD", 0.07),
    ("SG", "SGD", 0.04),
    ("JP", "JPY", 0.03),
]

INDUSTRIES = [
    "SaaS", "Fintech", "E-commerce", "Healthcare", "Logistics",
    "Media", "Education", "Manufacturing", "Gaming", "Real Estate",
]

# tier_rank orders the ladder so a plan change can be classified as an upgrade
# or a downgrade by comparing ranks.
PLANS = [
    # plan_id, plan_name, tier, tier_rank, seat_price_usd, billing_interval
    ("PLAN-STARTER-M", "Starter Monthly", "Starter", 1, 12.0, "monthly"),
    ("PLAN-STARTER-A", "Starter Annual", "Starter", 1, 10.0, "annual"),
    ("PLAN-GROWTH-M", "Growth Monthly", "Growth", 2, 29.0, "monthly"),
    ("PLAN-GROWTH-A", "Growth Annual", "Growth", 2, 24.0, "annual"),
    ("PLAN-PRO-M", "Pro Monthly", "Pro", 3, 59.0, "monthly"),
    ("PLAN-PRO-A", "Pro Annual", "Pro", 3, 49.0, "annual"),
    ("PLAN-ENT-M", "Enterprise Monthly", "Enterprise", 4, 99.0, "monthly"),
    ("PLAN-ENT-A", "Enterprise Annual", "Enterprise", 4, 85.0, "annual"),
]

# Monthly-heavy: annual contracts are ~12% of the book, which keeps the invoice
# cadence realistic (annual spells bill once upfront, not every month).
PLAN_WEIGHTS = [0.22, 0.03, 0.30, 0.05, 0.20, 0.03, 0.16, 0.01]

SPELL_CHURN_RATE = 0.08       # chance a spell ends in churn rather than a plan change
REACTIVATION_RATE = 0.22      # chance a churned customer returns after a gap

# --- Injection rates. Every one of these is asserted against in the manifest. ---
DUPLICATE_INVOICE_RATE = 0.02      # billing system replays a batch
LATE_ARRIVAL_RATE = 0.015          # records that land days after the event
LATE_THRESHOLD_DAYS = 3            # lag beyond which a record counts as late-arriving
TZ_BUG_SOURCE_SHARE = 0.08         # share of invoices from the broken source system
NULL_EMPLOYEE_COUNT_RATE = 0.12    # CRM field left blank
NULL_INDUSTRY_RATE = 0.07
NULL_PAYMENT_METHOD_RATE = 0.05
ORPHAN_INVOICE_RATE = 0.001        # invoice whose subscription never arrived

# The timezone bug: one source system writes IST wall-clock into a column its
# contract documents as UTC. Consumers reading it as UTC land 5h30m in the
# future, which rolls late-evening invoices into the next calendar day -- and,
# on the last day of a month, into the next month.
IST_OFFSET = timedelta(hours=5, minutes=30)
BROKEN_SOURCE = "billing_sync_v2"
CLEAN_SOURCE = "billing_sync_v1"


def month_range_start(end: date, months: int) -> date:
    """First day of the month `months` before `end`'s month."""
    total = (end.year * 12 + end.month - 1) - (months - 1)
    return date(total // 12, total % 12 + 1, 1)


def build_fx_rates(rng: np.random.Generator, start: date, end: date) -> pd.DataFrame:
    """Daily rate-to-USD per currency as a gentle random walk around base."""
    days = pd.date_range(start, end, freq="D")
    frames = []
    for ccy, base in CURRENCY_BASE_RATES.items():
        if ccy == "USD":
            rates = np.ones(len(days))
        else:
            # ~0.4% daily vol, mean-reverting enough to stay plausible over 2y.
            shocks = rng.normal(0, 0.004, len(days))
            drift = np.cumsum(shocks)
            drift -= np.linspace(0, drift[-1], len(days)) * 0.6
            rates = base * np.exp(drift)
        frames.append(pd.DataFrame({"rate_date": days, "currency_code": ccy, "rate_to_usd": rates}))
    fx = pd.concat(frames, ignore_index=True)
    fx["rate_to_usd"] = fx["rate_to_usd"].round(6)
    return fx


def build_employees(rng: np.random.Generator) -> pd.DataFrame:
    """A 5-level sales org that closes into a single root (self-referencing FK)."""
    rows = [{
        "employee_id": "EMP-00001",
        "manager_id": None,
        "full_name": "Dana Whitfield",
        "title": "Chief Revenue Officer",
        "region": "GLOBAL",
        "level": 0,
    }]
    next_id = 2
    regions = ["AMER", "EMEA", "APAC"]

    vps = []
    for region in regions:
        eid = f"EMP-{next_id:05d}"
        next_id += 1
        rows.append({"employee_id": eid, "manager_id": "EMP-00001",
                     "full_name": f"VP Sales {region}", "title": "VP Sales",
                     "region": region, "level": 1})
        vps.append((eid, region))

    directors = []
    for vp_id, region in vps:
        for i in range(3):
            eid = f"EMP-{next_id:05d}"
            next_id += 1
            rows.append({"employee_id": eid, "manager_id": vp_id,
                         "full_name": f"Director {region} {i + 1}", "title": "Sales Director",
                         "region": region, "level": 2})
            directors.append((eid, region))

    managers = []
    for dir_id, region in directors:
        for i in range(rng.integers(2, 4)):
            eid = f"EMP-{next_id:05d}"
            next_id += 1
            rows.append({"employee_id": eid, "manager_id": dir_id,
                         "full_name": f"Manager {region} {len(managers) + 1}", "title": "Sales Manager",
                         "region": region, "level": 3})
            managers.append((eid, region))

    account_managers = []
    for mgr_id, region in managers:
        for _ in range(rng.integers(3, 6)):
            eid = f"EMP-{next_id:05d}"
            next_id += 1
            rows.append({"employee_id": eid, "manager_id": mgr_id,
                         "full_name": f"AE {region} {len(account_managers) + 1}",
                         "title": "Account Executive", "region": region, "level": 4})
            account_managers.append(eid)

    df = pd.DataFrame(rows)
    df.attrs["account_managers"] = account_managers
    return df


def build_customers(rng: np.random.Generator, n: int, start: date, end: date,
                    account_managers: list[str]) -> pd.DataFrame:
    codes, ccys, weights = zip(*COUNTRIES)
    weights = np.array(weights) / np.sum(weights)
    idx = rng.choice(len(codes), size=n, p=weights)

    # Signups skew early: the window should open with an existing book of business.
    tenure_days = (end - start).days
    signup_offsets = (rng.beta(1.2, 3.2, n) * tenure_days).astype(int)
    signup_dates = np.array([start + timedelta(days=int(d)) for d in signup_offsets])

    df = pd.DataFrame({
        "customer_id": [f"CUST-{i:06d}" for i in range(1, n + 1)],
        "company_name": [f"{rng.choice(['Northwind', 'Acme', 'Globex', 'Initech', 'Umbra', 'Vertex', 'Lumen', 'Orbit', 'Cobalt', 'Fathom'])}"
                         f" {rng.choice(['Systems', 'Labs', 'Group', 'Digital', 'Works', 'Technologies'])} {i}"
                         for i in range(1, n + 1)],
        "country_code": [codes[i] for i in idx],
        "currency_code": [ccys[i] for i in idx],
        "industry": rng.choice(INDUSTRIES, size=n),
        "employee_count": rng.lognormal(4.2, 1.1, n).astype(int) + 5,
        "signup_date": signup_dates,
        "account_manager_id": rng.choice(account_managers, size=n),
    })

    # Injected: CRM fields operators skip. Optional-by-contract, so the models must
    # tolerate them -- but the *tests* pin which columns are allowed to be null.
    null_emp = rng.random(n) < NULL_EMPLOYEE_COUNT_RATE
    df.loc[null_emp, "employee_count"] = np.nan
    null_ind = rng.random(n) < NULL_INDUSTRY_RATE
    df.loc[null_ind, "industry"] = None

    df.attrs["injected"] = {
        "null_employee_count": int(null_emp.sum()),
        "null_industry": int(null_ind.sum()),
    }
    return df


def build_subscriptions(rng: np.random.Generator, customers: pd.DataFrame,
                        target_spells: int, end: date) -> pd.DataFrame:
    """Walk each customer through a chain of plan/seat spells until churn or window end.

    A "spell" is a contiguous period on one plan at one seat count. A plan change
    closes the current spell and opens the next, which is what lets the transform
    layer classify MRR movement (new / expansion / contraction / churn) by diffing
    consecutive spells.
    """
    plan_ids = [p[0] for p in PLANS]
    plan_rank = {p[0]: p[3] for p in PLANS}
    ranks_to_plans: dict[int, list[str]] = {}
    for p in PLANS:
        ranks_to_plans.setdefault(p[3], []).append(p[0])

    rows = []
    sub_seq = 1
    cust_records = customers[["customer_id", "signup_date", "employee_count"]].to_dict("records")

    # Rough per-customer spell budget to land near the target spell count.
    spells_per_customer = max(1, round(target_spells / len(cust_records)))

    for rec in cust_records:
        cursor = rec["signup_date"]
        if isinstance(cursor, np.datetime64):
            cursor = pd.Timestamp(cursor).date()
        seats = rec["employee_count"]
        seats = max(2, int(seats * rng.uniform(0.05, 0.30))) if pd.notna(seats) else int(rng.integers(3, 40))
        plan = rng.choice(plan_ids, p=PLAN_WEIGHTS)
        reason = "new"
        churned = False

        for spell_no in range(spells_per_customer + 4):
            if cursor >= end or churned:
                break

            # Spell length averages ~3.5 months, so a ~17-month tenure yields ~5 spells.
            duration = int(rng.integers(1, 7))
            spell_end = cursor + timedelta(days=duration * 30)
            open_ended = spell_end >= end
            if open_ended:
                spell_end = None

            rows.append({
                "subscription_id": f"SUB-{sub_seq:07d}",
                "customer_id": rec["customer_id"],
                "plan_id": plan,
                "seats": seats,
                "started_at": cursor,
                "ended_at": spell_end,
                "status": "active" if open_ended else "closed",
                "change_reason": reason,
            })
            sub_seq += 1
            if open_ended:
                break

            # What happens at the end of this spell?
            roll = rng.random()
            current_rank = plan_rank[plan]
            if roll < SPELL_CHURN_RATE:
                churned = True
                # A churned customer sometimes comes back after a gap.
                if rng.random() < REACTIVATION_RATE:
                    gap = int(rng.integers(30, 150))
                    cursor = spell_end + timedelta(days=gap)
                    if cursor < end:
                        churned = False
                        reason = "reactivation"
                        seats = max(2, int(seats * rng.uniform(0.6, 1.1)))
                        continue
                # Mark the spell we just wrote as the churn point.
                rows[-1]["status"] = "churned"
                break
            elif roll < 0.46 and current_rank < 4:
                plan = rng.choice(ranks_to_plans[current_rank + 1])
                reason = "upgrade"
            elif roll < 0.58 and current_rank > 1:
                plan = rng.choice(ranks_to_plans[current_rank - 1])
                reason = "downgrade"
            else:
                # Same plan, different seat count -- expansion/contraction without a plan move.
                factor = rng.uniform(1.05, 1.6) if rng.random() < 0.7 else rng.uniform(0.5, 0.95)
                new_seats = max(1, int(seats * factor))
                reason = "seat_change"
                seats = new_seats

            cursor = spell_end

    return pd.DataFrame(rows)


def _add_months_vectorized(dates: pd.Series, k: pd.Series) -> pd.Series:
    """Anniversary-safe month addition, applied in one pass per distinct k."""
    out = pd.Series(pd.NaT, index=dates.index, dtype="datetime64[ns]")
    for offset in np.unique(k):
        mask = k == offset
        out.loc[mask] = dates.loc[mask] + pd.DateOffset(months=int(offset))
    return out


def build_invoices(rng: np.random.Generator, subs: pd.DataFrame, plans: pd.DataFrame,
                   fx: pd.DataFrame, customers: pd.DataFrame, end: date) -> tuple[pd.DataFrame, dict]:
    """Explode each spell into billing periods, then each period into line items."""
    s = subs.merge(plans[["plan_id", "seat_price_usd", "billing_interval"]], on="plan_id", how="left")
    s = s.merge(customers[["customer_id", "currency_code"]], on="customer_id", how="left")
    s["started_at"] = pd.to_datetime(s["started_at"])
    s["effective_end"] = pd.to_datetime(s["ended_at"]).fillna(pd.Timestamp(end))

    # Monthly plans bill every month of the spell; annual plans bill once upfront.
    span_months = ((s["effective_end"] - s["started_at"]).dt.days // 30).clip(lower=1)
    s["n_periods"] = np.where(s["billing_interval"] == "monthly", span_months, 1)

    spell_idx = np.repeat(s.index.values, s["n_periods"].values)
    period_k = np.concatenate([np.arange(n) for n in s["n_periods"].values])

    inv = s.loc[spell_idx].reset_index(drop=True)
    inv["period_k"] = period_k
    inv["period_start"] = _add_months_vectorized(inv["started_at"], inv["period_k"])
    months_covered = np.where(inv["billing_interval"] == "monthly", 1, 12)
    inv["period_end"] = _add_months_vectorized(inv["period_start"], pd.Series(months_covered)) - pd.Timedelta(days=1)
    # An annual period cannot run past the spell.
    inv["period_end"] = inv[["period_end", "effective_end"]].min(axis=1)

    inv = inv[inv["period_start"] <= pd.Timestamp(end)].reset_index(drop=True)
    n = len(inv)

    # Invoices are issued on the period start, at a plausible hour of day.
    issue_seconds = rng.integers(0, 86400, n)
    inv["issued_at_true_utc"] = inv["period_start"] + pd.to_timedelta(issue_seconds, unit="s")
    inv["invoice_id"] = [f"INV-{i:07d}" for i in range(1, n + 1)]

    # Injected: one source system writes IST wall-clock into a UTC-typed column.
    broken = rng.random(n) < TZ_BUG_SOURCE_SHARE
    inv["source_system"] = np.where(broken, BROKEN_SOURCE, CLEAN_SOURCE)
    inv["issued_at"] = inv["issued_at_true_utc"] + pd.to_timedelta(np.where(broken, IST_OFFSET.total_seconds(), 0), unit="s")

    inv["status"] = rng.choice(["paid", "open", "void"], size=n, p=[0.91, 0.075, 0.015])
    paid = inv["status"] == "paid"
    inv["paid_at"] = pd.NaT
    inv.loc[paid, "paid_at"] = (inv.loc[paid, "issued_at"]
                                + pd.to_timedelta(rng.integers(0, 45, paid.sum()), unit="D"))
    inv["payment_method"] = rng.choice(["card", "ach", "wire", "sepa"], size=n, p=[0.55, 0.22, 0.13, 0.10])

    # Injected: payment_method missing on a slice of invoices. Note this is applied at
    # header grain, so it fans out to every line of the affected invoice -- the manifest
    # counts the result in the file, not the number of headers we touched.
    null_pm = rng.random(n) < NULL_PAYMENT_METHOD_RATE
    inv.loc[null_pm, "payment_method"] = None

    # Injected: late-arriving records. Normal ingestion is minutes behind the event;
    # this slice lands days later and will show up after its calendar month closed.
    normal_lag = pd.to_timedelta(rng.integers(60, 7200, n), unit="s")
    late = rng.random(n) < LATE_ARRIVAL_RATE
    late_lag = pd.to_timedelta(rng.integers(3, 31, n), unit="D")
    inv["ingested_at"] = inv["issued_at"] + np.where(late, late_lag, normal_lag)

    # --- Explode invoice headers into line items ---
    line_frames = []

    def emit(mask: np.ndarray, line_type: str, amount: np.ndarray) -> None:
        sub = inv.loc[mask, ["invoice_id", "customer_id", "subscription_id", "period_start",
                             "period_end", "issued_at", "status", "paid_at", "payment_method",
                             "currency_code", "source_system", "ingested_at"]].copy()
        sub["line_type"] = line_type
        sub["amount_local"] = amount[mask]
        line_frames.append(sub)

    fx_at_issue = (fx.assign(rate_date=pd.to_datetime(fx["rate_date"]))
                     .rename(columns={"rate_date": "period_start"}))
    inv = inv.merge(fx_at_issue, on=["period_start", "currency_code"], how="left")
    inv["rate_to_usd"] = inv["rate_to_usd"].ffill().fillna(1.0)

    months_mult = np.where(inv["billing_interval"] == "monthly", 1, 12)
    base_usd = inv["seats"].to_numpy() * inv["seat_price_usd"].to_numpy() * months_mult
    base_local = base_usd * inv["rate_to_usd"].to_numpy()

    all_rows = np.ones(len(inv), dtype=bool)
    emit(all_rows, "subscription", np.round(base_local, 2))

    tax_mask = rng.random(len(inv)) < 0.95
    emit(tax_mask, "tax", np.round(base_local * rng.uniform(0.05, 0.20, len(inv)), 2))

    addon_mask = rng.random(len(inv)) < 0.55
    emit(addon_mask, "seats_addon", np.round(base_local * rng.uniform(0.05, 0.35, len(inv)), 2))

    overage_mask = rng.random(len(inv)) < 0.45
    emit(overage_mask, "overage", np.round(base_local * rng.uniform(0.02, 0.18, len(inv)), 2))

    discount_mask = rng.random(len(inv)) < 0.35
    emit(discount_mask, "discount", -np.round(base_local * rng.uniform(0.05, 0.25, len(inv)), 2))

    # Pro/Enterprise contracts carry a platform fee and an optional support plan as
    # separate lines -- these are the ones finance most often forgets to exclude.
    platform_mask = (rng.random(len(inv)) < 0.60)
    emit(platform_mask, "platform_fee", np.round(base_local * rng.uniform(0.03, 0.09, len(inv)), 2))

    support_mask = (rng.random(len(inv)) < 0.45)
    emit(support_mask, "support_plan", np.round(base_local * rng.uniform(0.08, 0.22, len(inv)), 2))

    # Annual spells cut short by a plan change get a prorated credit back.
    early_term = ((inv["billing_interval"] == "annual")
                  & (inv["effective_end"] < inv["period_end"])).to_numpy()
    emit(early_term, "proration_credit", -np.round(base_local * rng.uniform(0.1, 0.7, len(inv)), 2))

    lines = pd.concat(line_frames, ignore_index=True)
    lines = lines.sort_values(["invoice_id", "line_type"]).reset_index(drop=True)
    lines["line_number"] = lines.groupby("invoice_id").cumcount() + 1

    # Injected: the billing system replays batches, re-emitting lines verbatim except
    # for ingestion metadata. Dedup must key on (invoice_id, line_number) and keep
    # the latest ingested_at -- a naive DISTINCT would not catch these.
    n_dupes = int(len(lines) * DUPLICATE_INVOICE_RATE)
    dupe_idx = rng.choice(len(lines), size=n_dupes, replace=False)
    dupes = lines.iloc[dupe_idx].copy()
    dupes["ingested_at"] = dupes["ingested_at"] + pd.to_timedelta(rng.integers(1, 72, n_dupes), unit="h")

    # Injected: invoices whose parent subscription never made it into the extract.
    n_orphans = int(len(lines) * ORPHAN_INVOICE_RATE)
    orphan_idx = rng.choice(len(lines), size=n_orphans, replace=False)
    orphans = lines.iloc[orphan_idx].copy()
    orphans["invoice_id"] = [f"INV-ORPH-{i:05d}" for i in range(1, n_orphans + 1)]
    orphans["subscription_id"] = [f"SUB-9{i:06d}" for i in range(1, n_orphans + 1)]

    lines = pd.concat([lines, dupes, orphans], ignore_index=True)
    lines = lines.sample(frac=1.0, random_state=int(rng.integers(0, 2**31))).reset_index(drop=True)

    return lines, {"invoice_headers": int(n)}


def measure_injections(lines: pd.DataFrame, subs: pd.DataFrame) -> dict:
    """Count every injected defect as it actually exists in invoices.csv.

    Deliberately measured on the finished file rather than tracked as we inject.
    Defects are injected at invoice-header grain but the file is at line grain, so
    counting at injection time under-reports by the fan-out factor -- which is a
    mistake this project made once and the test suite caught. Anything the README
    or a dbt test quotes has to be a number someone could reproduce by opening the
    CSV and counting.
    """
    issued = pd.to_datetime(lines["issued_at"])
    ingested = pd.to_datetime(lines["ingested_at"])

    broken = lines["source_system"] == BROKEN_SOURCE
    true_utc = issued.copy()
    true_utc.loc[broken] = issued.loc[broken] - IST_OFFSET

    # A day crossing misdates the invoice; a month crossing misstates a closed
    # month's revenue, which is the one finance actually notices.
    tz_day = int((broken & (issued.dt.date != true_utc.dt.date)).sum())
    tz_month = int((broken & (issued.dt.to_period("M") != true_utc.dt.to_period("M"))).sum())

    lag_days = (ingested - issued).dt.total_seconds() / 86400

    return {
        "duplicate_lines": int(lines.duplicated(subset=["invoice_id", "line_number"], keep="first").sum()),
        "orphan_lines": int((~lines["subscription_id"].isin(set(subs["subscription_id"]))).sum()),
        "late_arriving_lines": int((lag_days > LATE_THRESHOLD_DAYS).sum()),
        "null_payment_method": int(lines["payment_method"].isna().sum()),
        "tz_bug_source_rows": int(broken.sum()),
        "tz_bug_day_boundary_crossings": tz_day,
        "tz_bug_month_boundary_crossings": tz_month,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--customers", type=int, default=10_000)
    ap.add_argument("--subscriptions", type=int, default=50_000, help="target spell count")
    ap.add_argument("--months", type=int, default=24)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", type=Path, default=Path("data/raw"))
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    end = ANCHOR_END
    start = month_range_start(end, args.months)
    args.out.mkdir(parents=True, exist_ok=True)

    print(f"window          : {start} -> {end} ({args.months} months)")

    fx = build_fx_rates(rng, start, end)
    employees = build_employees(rng)
    customers = build_customers(rng, args.customers, start, end, employees.attrs["account_managers"])
    plans = pd.DataFrame(PLANS, columns=["plan_id", "plan_name", "tier", "tier_rank",
                                         "seat_price_usd", "billing_interval"])
    subs = build_subscriptions(rng, customers, args.subscriptions, end)
    lines, inv_stats = build_invoices(rng, subs, plans, fx, customers, end)
    injected = measure_injections(lines, subs)

    tables = {
        "customers": customers,
        "employees": employees.drop(columns=["level"]),
        "plans": plans,
        "subscriptions": subs,
        "invoices": lines,
        "fx_rates": fx,
    }
    for name, df in tables.items():
        path = args.out / f"{name}.csv"
        df.to_csv(path, index=False)
        print(f"{name:<16}: {len(df):>9,} rows -> {path}")

    manifest = {
        "generated_at_utc": datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "seed": args.seed,
        "window": {"start": str(start), "end": str(end), "months": args.months},
        "row_counts": {name: int(len(df)) for name, df in tables.items()},
        "invoice_headers": inv_stats["invoice_headers"],
        "note": "Counts are measured on the emitted files. 'rate' is the injection knob "
                "applied at its natural grain, which is not always the grain of the file: "
                "invoice defects are injected per header and fan out across that invoice's "
                "line items, so count/rows does not equal rate.",
        "injected_problems": {
            "duplicate_invoice_lines": {
                "count": injected["duplicate_lines"],
                "rate": DUPLICATE_INVOICE_RATE,
                "grain": "line",
                "detail": "Billing batch replay: line re-emitted verbatim, later ingested_at. "
                          "Dedup on (invoice_id, line_number) keeping max(ingested_at). A naive "
                          "SELECT DISTINCT will not remove these -- ingested_at differs.",
            },
            "orphan_invoice_lines": {
                "count": injected["orphan_lines"],
                "rate": ORPHAN_INVOICE_RATE,
                "grain": "line",
                "detail": "Invoice references a subscription_id absent from subscriptions.csv. "
                          "Caught by the dbt relationships test on stg_invoices.",
            },
            "late_arriving_invoices": {
                "count": injected["late_arriving_lines"],
                "rate": LATE_ARRIVAL_RATE,
                "grain": "header, fanned out to lines",
                "threshold_days": LATE_THRESHOLD_DAYS,
                "detail": f"ingested_at is 3-30 days after issued_at, i.e. lands after its "
                          f"calendar month closed. Counted as lines whose ingest lag exceeds "
                          f"{LATE_THRESHOLD_DAYS} days. Forces incremental models to reprocess "
                          f"a trailing window rather than only the current month.",
            },
            "timezone_bug": {
                "source_system": BROKEN_SOURCE,
                "affected_rows": injected["tz_bug_source_rows"],
                "day_boundary_crossings": injected["tz_bug_day_boundary_crossings"],
                "month_boundary_crossings": injected["tz_bug_month_boundary_crossings"],
                "grain": "header, fanned out to lines",
                "detail": f"{BROKEN_SOURCE} writes IST wall-clock (UTC+5:30) into issued_at, a "
                          "column its contract documents as UTC. Rows near midnight roll to the "
                          "next day; rows on a month's last evening roll into the next month and "
                          "misstate a closed month's revenue. Only the month crossings move money "
                          "between reporting periods -- that is the number worth quoting.",
            },
            "null_employee_count": {"count": int(customers.attrs["injected"]["null_employee_count"]),
                                    "rate": NULL_EMPLOYEE_COUNT_RATE,
                                    "grain": "customer",
                                    "detail": "Optional CRM field left blank."},
            "null_industry": {"count": int(customers.attrs["injected"]["null_industry"]),
                              "rate": NULL_INDUSTRY_RATE,
                              "grain": "customer",
                              "detail": "Optional CRM field left blank."},
            "null_payment_method": {"count": injected["null_payment_method"],
                                    "rate": NULL_PAYMENT_METHOD_RATE,
                                    "grain": "header, fanned out to lines",
                                    "detail": "Missing on a slice of invoices; affects every line "
                                              "of those invoices."},
        },
    }
    manifest_path = args.out / "_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"\nmanifest        : {manifest_path}")
    print(f"invoice headers : {inv_stats['invoice_headers']:,}")
    print(f"duplicate lines : {injected['duplicate_lines']:,}")
    print(f"orphan lines    : {injected['orphan_lines']:,}")
    print(f"late arrivals   : {injected['late_arriving_lines']:,}")
    print(f"tz bug          : {injected['tz_bug_source_rows']:,} shifted rows -> "
          f"{injected['tz_bug_day_boundary_crossings']:,} misdated days, "
          f"{injected['tz_bug_month_boundary_crossings']:,} crossed a month close")


if __name__ == "__main__":
    main()
