"""Reproduce the fan-out join that doubled revenue, against the real generated data.

This exists because "a report showed 2x revenue and we traced it to a join" is a
story, and a story is not evidence. The numbers in fanout_diagnosis.md come from
running this — no Snowflake or Power BI required, because the bug is not a Snowflake
or Power BI bug. It is a cardinality bug, and cardinality is arithmetic.

The scenario is the real one: dim_customer joins customers to employees to flatten
the sales org onto each account. If employee_id is not unique in the employees
extract, that join fans out, every affected customer appears twice in the dimension,
and every measure sliced by the dimension doubles for those customers.

    python powerbi/fanout_repro.py

Requires data/raw/ — run `python data_generator/simulate.py` first.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

RAW = Path(__file__).resolve().parents[1] / "data" / "raw"


def load() -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    if not (RAW / "customers.csv").exists():
        sys.exit(f"No data in {RAW}. Run: python data_generator/simulate.py")
    return (
        pd.read_csv(RAW / "customers.csv"),
        pd.read_csv(RAW / "employees.csv"),
        pd.read_csv(RAW / "invoices.csv"),
    )


def build_revenue(invoices: pd.DataFrame) -> pd.DataFrame:
    """A stand-in for fct_revenue: revenue per customer.

    Deliberately simplified — deduplicated, tax excluded, voids excluded, no
    allocation. The fan-out has nothing to do with any of that, and a faithful
    reimplementation of the mart would obscure the one thing being demonstrated.
    """
    clean = invoices.drop_duplicates(subset=["invoice_id", "line_number"], keep="first")
    clean = clean[(clean["line_type"] != "tax") & (clean["invoice_status"] != "void")] \
        if "invoice_status" in clean.columns else clean[clean["line_type"] != "tax"]
    clean = clean[clean["status"] != "void"] if "status" in clean.columns else clean
    return clean.groupby("customer_id", as_index=False)["amount_local"].sum() \
                .rename(columns={"amount_local": "revenue"})


def build_dim_customer(customers: pd.DataFrame, employees: pd.DataFrame) -> pd.DataFrame:
    """dim_customer: accounts with their account manager attached."""
    return customers.merge(
        employees[["employee_id", "full_name", "region"]],
        left_on="account_manager_id",
        right_on="employee_id",
        how="left",
    )


def main() -> None:
    customers, employees, invoices = load()
    revenue = build_revenue(invoices)

    print("=" * 78)
    print("FAN-OUT JOIN REPRODUCTION")
    print("=" * 78)

    # ---- The correct world -------------------------------------------------
    dim_ok = build_dim_customer(customers, employees)
    report_ok = revenue.merge(dim_ok, on="customer_id", how="inner")
    total_ok = report_ok["revenue"].sum()

    print(f"\nemployees.employee_id unique?   {employees['employee_id'].is_unique}")
    print(f"dim_customer rows               {len(dim_ok):,}  (customers: {len(customers):,})")
    print(f"Total revenue (correct)         {total_ok:>18,.2f}")

    # ---- Break it exactly the way a real extract breaks --------------------
    #
    # One employee appears twice. This is not contrived: it is what a re-hire, a
    # merged CRM record, or an extract that forgot a `WHERE is_current` produces.
    # A single duplicated row in a 123-row dimension table.
    duplicated_ae = employees[employees["title"] == "Account Executive"].iloc[0]
    employees_broken = pd.concat([employees, duplicated_ae.to_frame().T], ignore_index=True)

    dim_broken = build_dim_customer(customers, employees_broken)
    report_broken = revenue.merge(dim_broken, on="customer_id", how="inner")
    total_broken = report_broken["revenue"].sum()

    affected = dim_broken[dim_broken["account_manager_id"] == duplicated_ae["employee_id"]]
    n_affected_customers = affected["customer_id"].nunique()

    inflation = total_broken - total_ok
    inflation_pct = 100.0 * inflation / total_ok

    print("\n" + "-" * 78)
    print(f"INJECTED: employee_id {duplicated_ae['employee_id']} "
          f"({duplicated_ae['full_name']}) duplicated — 1 extra row in a "
          f"{len(employees)}-row table")
    print("-" * 78)
    print(f"employees.employee_id unique?   {employees_broken['employee_id'].is_unique}")
    print(f"dim_customer rows               {len(dim_broken):,}  "
          f"(+{len(dim_broken) - len(dim_ok)})")
    print(f"Customers on that AE            {n_affected_customers:,} "
          f"({100.0 * n_affected_customers / len(customers):.1f}% of the book)")
    print(f"\nTotal revenue (correct)         {total_ok:>18,.2f}")
    print(f"Total revenue (fanned out)      {total_broken:>18,.2f}")
    print(f"Inflation                       {inflation:>18,.2f}  "
          f"({inflation_pct:+.2f}%)")

    # ---- Why it is so hard to spot ----------------------------------------
    affected_ids = set(affected["customer_id"])
    rev_affected = revenue[revenue["customer_id"].isin(affected_ids)]["revenue"].sum()

    print("\n" + "-" * 78)
    print("WHY IT SURVIVES REVIEW")
    print("-" * 78)
    print(f"Company total moves by          {inflation_pct:+.2f}%  <- plausible; nobody blinks")
    print(f"But those {n_affected_customers} customers are")
    print(f"  reported at                   {rev_affected * 2:>18,.2f}")
    print(f"  actually worth                {rev_affected:>18,.2f}")
    print(f"  i.e. exactly                  {(rev_affected * 2) / rev_affected:>18.1f}x")
    print("\nThe company number looks fine. One AE's number is exactly double.")
    print("That is why this gets found by an account manager checking their own")
    print("commission, not by anyone reviewing the dashboard.")

    # ---- The test that catches it -----------------------------------------
    print("\n" + "-" * 78)
    print("THE TEST THAT CATCHES IT")
    print("-" * 78)

    dupes = employees_broken[employees_broken.duplicated(subset=["employee_id"], keep=False)]
    print(f"unique(stg_employees.employee_id) -> FAILS, {len(dupes)} rows share "
          f"employee_id {duplicated_ae['employee_id']}")

    grain_broken = report_broken.groupby("customer_id").size()
    n_dupe_rows = int((grain_broken > 1).sum())
    print(f"unique_combination(customer_id) on the report -> FAILS, "
          f"{n_dupe_rows:,} customers appear more than once")

    print("\nBoth already exist in this project "
          "(dbt_project/models/staging/_staging__models.yml).")
    print("The fan-out is caught in CI, before the dashboard, by a one-line "
          "`unique` test on a\ndimension nobody thinks is interesting.")
    print("=" * 78)


if __name__ == "__main__":
    main()
