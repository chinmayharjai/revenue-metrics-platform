"""Tests for the data simulator.

The point of these is not that the generator "runs" -- it is that the manifest
tells the truth. Every downstream claim in the README and every dbt test that
says "catches N bad rows" is anchored to _manifest.json, so the manifest is a
contract and these tests are what hold it to account.

Run:  pytest tests/ -v
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pandas as pd
import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

# Small but not tiny: big enough that every injection fires at least once.
SAMPLE_CUSTOMERS = 400
SAMPLE_SUBSCRIPTIONS = 2000


@pytest.fixture(scope="module")
def dataset(tmp_path_factory) -> dict:
    """Generate a fresh sample dataset once and hand the tables to every test."""
    out = tmp_path_factory.mktemp("raw")
    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "data_generator" / "simulate.py"),
         "--customers", str(SAMPLE_CUSTOMERS),
         "--subscriptions", str(SAMPLE_SUBSCRIPTIONS),
         "--seed", "42",
         "--out", str(out)],
        capture_output=True, text=True, cwd=REPO_ROOT,
    )
    assert result.returncode == 0, f"simulator failed:\n{result.stderr}"

    return {
        "manifest": json.loads((out / "_manifest.json").read_text()),
        "customers": pd.read_csv(out / "customers.csv"),
        "employees": pd.read_csv(out / "employees.csv"),
        "plans": pd.read_csv(out / "plans.csv"),
        "subscriptions": pd.read_csv(out / "subscriptions.csv"),
        "invoices": pd.read_csv(out / "invoices.csv"),
        "fx_rates": pd.read_csv(out / "fx_rates.csv"),
    }


def test_manifest_row_counts_match_files(dataset):
    for name, count in dataset["manifest"]["row_counts"].items():
        assert len(dataset[name]) == count, f"{name}: manifest says {count}, file has {len(dataset[name])}"


def test_customer_ids_unique(dataset):
    ids = dataset["customers"]["customer_id"]
    assert ids.is_unique


def test_subscription_ids_unique(dataset):
    assert dataset["subscriptions"]["subscription_id"].is_unique


def test_every_subscription_points_at_a_real_customer(dataset):
    subs, customers = dataset["subscriptions"], dataset["customers"]
    assert subs["customer_id"].isin(set(customers["customer_id"])).all()


def test_org_hierarchy_closes_into_a_single_root(dataset):
    """The recursive CTE showcase depends on exactly one root and no orphan managers."""
    emp = dataset["employees"]
    roots = emp[emp["manager_id"].isna()]
    assert len(roots) == 1, f"expected 1 root, got {len(roots)}"

    known = set(emp["employee_id"])
    non_root = emp[emp["manager_id"].notna()]
    assert non_root["manager_id"].isin(known).all(), "manager_id pointing outside the org"


def test_org_hierarchy_is_acyclic(dataset):
    """Walk every node to the root; a cycle would hang the recursive CTE."""
    emp = dataset["employees"]
    parent = dict(zip(emp["employee_id"], emp["manager_id"]))
    for start in emp["employee_id"]:
        seen, node, depth = {start}, parent[start], 0
        while isinstance(node, str):
            assert node not in seen, f"cycle reached from {start} at {node}"
            seen.add(node)
            node = parent[node]
            depth += 1
            assert depth < 20, f"suspiciously deep chain from {start}"


# --- Injected-problem contract: each of these must actually be present ---

def test_duplicate_lines_injected_at_expected_rate(dataset):
    inv = dataset["invoices"]
    declared = dataset["manifest"]["injected_problems"]["duplicate_invoice_lines"]["count"]
    dupes = inv.duplicated(subset=["invoice_id", "line_number"], keep="first").sum()
    assert dupes == declared, f"manifest declares {declared} duplicate lines, found {dupes}"
    assert declared > 0


def test_duplicates_differ_only_in_ingestion_metadata(dataset):
    """A replayed line must be byte-identical except ingested_at, or dedup-keep-latest is wrong."""
    inv = dataset["invoices"]
    dup_keys = inv[inv.duplicated(subset=["invoice_id", "line_number"], keep=False)]
    business_cols = ["invoice_id", "line_number", "customer_id", "subscription_id",
                     "line_type", "amount_local", "currency_code"]
    per_key = dup_keys.groupby(["invoice_id", "line_number"])[business_cols].nunique()
    assert (per_key.drop(columns=["invoice_id", "line_number"], errors="ignore") <= 1).all().all(), \
        "duplicate lines disagree on business values -- dedup would be ambiguous"


def test_orphan_invoices_reference_missing_subscriptions(dataset):
    inv, subs = dataset["invoices"], dataset["subscriptions"]
    declared = dataset["manifest"]["injected_problems"]["orphan_invoice_lines"]["count"]
    known = set(subs["subscription_id"])
    orphans = inv[~inv["subscription_id"].isin(known)]
    assert len(orphans) == declared, f"manifest declares {declared} orphans, found {len(orphans)}"


def test_late_arriving_records_land_after_their_event(dataset):
    inv = dataset["invoices"]
    issued = pd.to_datetime(inv["issued_at"])
    ingested = pd.to_datetime(inv["ingested_at"])
    assert (ingested >= issued).all(), "a record was ingested before it was issued"
    lag_days = (ingested - issued).dt.total_seconds() / 86400
    assert (lag_days > 3).any(), "no late-arriving records were injected"


def test_timezone_bug_confined_to_the_broken_source(dataset):
    """Only billing_sync_v2 rows carry the IST shift; v1 must be clean."""
    inv = dataset["invoices"]
    tz = dataset["manifest"]["injected_problems"]["timezone_bug"]
    assert tz["affected_rows"] > 0
    assert tz["day_boundary_crossings"] > 0

    sources = set(inv["source_system"].unique())
    assert sources == {"billing_sync_v1", "billing_sync_v2"}, sources

    broken_rows = (inv["source_system"] == "billing_sync_v2").sum()
    assert broken_rows == tz["affected_rows"], \
        f"manifest declares {tz['affected_rows']} shifted rows, found {broken_rows}"


def test_declared_nulls_are_present(dataset):
    m = dataset["manifest"]["injected_problems"]
    customers, invoices = dataset["customers"], dataset["invoices"]
    assert customers["employee_count"].isna().sum() == m["null_employee_count"]["count"]
    assert customers["industry"].isna().sum() == m["null_industry"]["count"]
    assert invoices["payment_method"].isna().sum() == m["null_payment_method"]["count"]


def test_columns_that_must_never_be_null(dataset):
    """Keys and amounts are non-negotiable -- nulls here would mean a generator bug,
    not an injection, and the staging not_null tests would be catching our own mess."""
    inv = dataset["invoices"]
    for col in ["invoice_id", "line_number", "customer_id", "subscription_id",
                "amount_local", "currency_code", "issued_at"]:
        assert inv[col].isna().sum() == 0, f"unexpected nulls in {col}"


# --- Business-shape sanity: the data has to be worth modelling ---

def test_subscription_spells_do_not_overlap_per_customer(dataset):
    """Overlapping spells would double-count MRR; the spell chain must be sequential."""
    subs = dataset["subscriptions"].copy()
    subs["started_at"] = pd.to_datetime(subs["started_at"])
    subs["ended_at"] = pd.to_datetime(subs["ended_at"])
    for _, grp in subs.sort_values("started_at").groupby("customer_id"):
        ends = grp["ended_at"].tolist()
        starts = grp["started_at"].tolist()
        for i in range(len(grp) - 1):
            if pd.notna(ends[i]):
                assert ends[i] <= starts[i + 1], "overlapping spells for one customer"


def test_all_movement_types_present(dataset):
    """The MRR waterfall needs every movement type to exist or it proves nothing."""
    reasons = set(dataset["subscriptions"]["change_reason"].unique())
    assert {"new", "upgrade", "downgrade", "seat_change"}.issubset(reasons), reasons


def test_churn_actually_happens(dataset):
    statuses = set(dataset["subscriptions"]["status"].unique())
    assert "churned" in statuses
    assert "active" in statuses


def test_multi_currency_with_fx_coverage(dataset):
    """Every currency in the book needs a rate on every day, or normalization silently drops revenue."""
    invoices, fx = dataset["invoices"], dataset["fx_rates"]
    used = set(invoices["currency_code"].unique())
    assert len(used) > 1, "single-currency data defeats the normalization logic"
    covered = set(fx["currency_code"].unique())
    assert used.issubset(covered), f"no FX rates for {used - covered}"


def test_usd_rate_is_identity(dataset):
    usd = dataset["fx_rates"].query("currency_code == 'USD'")
    assert (usd["rate_to_usd"] == 1.0).all()


def test_credit_lines_are_negative_and_charges_are_not(dataset):
    inv = dataset["invoices"]
    credits = inv[inv["line_type"].isin(["discount", "proration_credit"])]
    charges = inv[inv["line_type"].isin(["subscription", "tax", "platform_fee"])]
    assert (credits["amount_local"] <= 0).all(), "a credit line was positive"
    assert (charges["amount_local"] >= 0).all(), "a charge line was negative"


def test_generation_is_deterministic_for_a_seed(tmp_path):
    """Same seed, same bytes. Without this the 'measured numbers' in the README rot."""
    def run(out: Path) -> str:
        subprocess.run(
            [sys.executable, str(REPO_ROOT / "data_generator" / "simulate.py"),
             "--customers", "120", "--subscriptions", "500", "--seed", "7", "--out", str(out)],
            capture_output=True, text=True, cwd=REPO_ROOT, check=True,
        )
        return (out / "invoices.csv").read_text()

    assert run(tmp_path / "a") == run(tmp_path / "b")
