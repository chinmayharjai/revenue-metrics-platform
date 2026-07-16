"""Nightly revenue ELT: extract -> load -> dbt run -> dbt test -> freshness.

Schedule: 03:00 UTC daily. Late enough that the previous day's billing batches have
settled, early enough that a failure leaves a working day to fix it before the
Americas open a dashboard.

The dependency shape is the interesting part, and it is not the obvious one:

    extract >> load >> [source_freshness, dbt_run] ; dbt_run >> dbt_test >> publish

Source freshness runs *after* the load rather than before it, and in parallel with
dbt_run rather than gating it. The reasoning is in the task's docstring, because
the wrong order here is the single most common way a freshness check becomes
decoration.

Everything is designed around one property: **a rerun of this DAG for the same
logical date produces the same result as the first run.** Not "does not crash" —
produces the same tables. That is what makes the recovery procedure in
runbooks/dag_failure_recovery.md be "clear the task and let it run" rather than a
paragraph of manual reasoning about what half-finished.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from airflow.decorators import task_group
from airflow.models.dag import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.empty import EmptyOperator
from airflow.providers.slack.notifications.slack_webhook import send_slack_webhook_notification

DBT_PROJECT_DIR = os.environ.get("DBT_PROJECT_DIR", "/opt/airflow/dbt_project")
DBT_PROFILES_DIR = os.environ.get("DBT_PROFILES_DIR", "/opt/airflow/.dbt")
DATA_DIR = os.environ.get("REVENUE_DATA_DIR", "/opt/airflow/data")

# `dbt build` is deliberately not used anywhere below. It interleaves models and
# tests, so a test failure on an early model leaves later models unbuilt and the
# warehouse in a half-published state. Splitting run and test means a test failure
# happens with every model built and consistent — you know exactly what you have,
# and the publish gate simply never opens.
DBT_ENV = {
    "DBT_PROFILES_DIR": DBT_PROFILES_DIR,
    # Credentials come from the environment, injected by the container from a
    # secrets backend. Nothing here is a literal, and nothing is an Airflow
    # Variable — Variables are visible in the UI to anyone with read access.
    "SNOWFLAKE_ACCOUNT": "{{ var.value.get('snowflake_account', '') }}",
    "SNOWFLAKE_USER": "{{ var.value.get('snowflake_user', '') }}",
    "SNOWFLAKE_PRIVATE_KEY_PATH": "{{ var.value.get('snowflake_private_key_path', '') }}",
    "SNOWFLAKE_PRIVATE_KEY_PASSPHRASE": "{{ conn.snowflake_default.password }}",
}

slack_failure_alert = send_slack_webhook_notification(
    slack_webhook_conn_id="slack_alerts",
    text=(
        ":red_circle: *Revenue ELT failed*\n"
        "*DAG:* {{ dag.dag_id }}\n"
        "*Task:* {{ ti.task_id }}\n"
        "*Logical date:* {{ ds }}\n"
        "*Try:* {{ ti.try_number }} of {{ ti.max_tries }}\n"
        "*Log:* {{ ti.log_url }}\n"
        "Runbook: runbooks/dag_failure_recovery.md"
    ),
)

default_args = {
    "owner": "data-platform",
    "depends_on_past": False,
    # depends_on_past=False is a real decision, not a default left alone.
    #
    # True would be defensible: this is a full-refresh pipeline, so a failed
    # Tuesday does not corrupt Wednesday. But True means one bad night blocks every
    # subsequent run until a human intervenes, and since each run rebuilds
    # everything from raw, Wednesday's run would have fixed Tuesday's damage
    # anyway. Blocking it converts a one-night outage into a multi-day one.
    #
    # This would flip to True the moment any model became genuinely incremental,
    # because then a skipped day leaves a permanent hole.

    "retries": 3,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=30),
    # Exponential backoff because the failures worth retrying are transient and
    # time-dependent: a suspended warehouse resuming, a rate limit, a network blip.
    # Retrying those at a fixed 30s hammers a service that is already struggling.
    # Backoff (5m -> 10m -> 20m, capped at 30m) gives it room. Failures that are
    # NOT worth retrying — a SQL error, a failed test — will fail identically three
    # times and just delay the alert by 35 minutes. That is the accepted cost;
    # tuning retries per task by failure class is the refinement if it starts to
    # hurt.

    "on_failure_callback": [slack_failure_alert],
    "email_on_failure": False,
}

with DAG(
    dag_id="revenue_elt",
    description="Nightly SaaS revenue ELT: CSV -> Snowflake RAW -> dbt marts",
    start_date=datetime(2024, 7, 1),
    schedule="0 3 * * *",
    catchup=False,
    # catchup=False because this pipeline full-refreshes from a fixed 24-month
    # window. Backfilling 700 logical dates would run the identical job 700 times
    # and produce the identical table 700 times. If the models were incremental
    # and partitioned by logical date, this would be True and the whole DAG would
    # need to key off {{ ds }} rather than rebuilding.

    max_active_runs=1,
    # One run at a time. Two concurrent runs would have two dbt processes writing
    # the same models in the same schema, and the loser's partial results become
    # the published marts. This is the cheapest guard against a class of bug that
    # is almost impossible to diagnose from the resulting data.

    dagrun_timeout=timedelta(hours=2),
    default_args=default_args,
    tags=["revenue", "dbt", "snowflake", "elt"],
    doc_md=__doc__,
) as dag:

    start = EmptyOperator(task_id="start")

    @task_group(group_id="extract")
    def extract_group():
        """Produce the source CSVs.

        Stands in for what would be an API pull or a CDC read from the billing
        system. It is a task group of one rather than a bare task because that is
        where the real extracts would go, one per source, in parallel — and a
        group with an obvious shape beats a group with an obvious future
        refactor.
        """
        BashOperator(
            task_id="generate_source_extracts",
            bash_command=(
                f"cd {DATA_DIR}/.. && "
                "python data_generator/simulate.py --out data/raw --seed 42"
            ),
            # Seeded, so re-running produces byte-identical files. That is what
            # makes the whole DAG rerunnable: a non-deterministic extract would
            # mean every retry loads different data and the reconciliation test
            # would compare today's staging to yesterday's raw.
            execution_timeout=timedelta(minutes=15),
        )

    @task_group(group_id="load_to_snowflake")
    def load_group():
        """PUT the CSVs to the stage, then COPY INTO the raw tables.

        Split into two tasks because they fail for entirely different reasons and
        the fix differs. A PUT failure is a network or credential problem; a COPY
        failure is a data or schema problem. Fusing them into one task means the
        runbook starts with "read the log to work out which half broke".
        """
        put = BashOperator(
            task_id="put_files_to_stage",
            bash_command=(
                "snowsql -a $SNOWFLAKE_ACCOUNT -u $SNOWFLAKE_USER -r LOADER -w WH_LOADING "
                f"-q \"PUT file://{DATA_DIR}/raw/*.csv @REVENUE_RAW.BILLING.STG_LANDING "
                'AUTO_COMPRESS = TRUE OVERWRITE = TRUE;"'
            ),
            # OVERWRITE = TRUE is what makes a retry safe. Without it a re-PUT
            # accumulates customers_1.csv.gz alongside customers.csv.gz, the COPY
            # globs both, and every row loads twice — a silent doubling that looks
            # like a dbt bug three tasks later.
            env=DBT_ENV,
            append_env=True,
            execution_timeout=timedelta(minutes=20),
        )

        copy = BashOperator(
            task_id="copy_into_raw",
            bash_command=(
                "snowsql -a $SNOWFLAKE_ACCOUNT -u $SNOWFLAKE_USER -r LOADER -w WH_LOADING "
                "-f /opt/airflow/snowflake_setup/03_copy_into.sql"
            ),
            # The same file a human runs by hand (snowflake_setup/03_copy_into.sql).
            # Not a copy of it. The moment the DAG has its own private version of
            # the load SQL, the two drift, and the version that gets tested is the
            # one nobody runs at 03:00.
            env=DBT_ENV,
            append_env=True,
            execution_timeout=timedelta(minutes=30),
        )

        put >> copy

    @task_group(group_id="transform")
    def transform_group():
        """dbt deps -> run -> test."""
        deps = BashOperator(
            task_id="dbt_deps",
            bash_command=f"cd {DBT_PROJECT_DIR} && dbt deps",
            env=DBT_ENV,
            append_env=True,
            execution_timeout=timedelta(minutes=5),
        )

        run = BashOperator(
            task_id="dbt_run",
            bash_command=f"cd {DBT_PROJECT_DIR} && dbt run --target prod",
            env=DBT_ENV,
            append_env=True,
            execution_timeout=timedelta(minutes=45),
            # SLA is on dbt_run rather than on the DAG as a whole because it is the
            # task whose duration actually tracks the thing worth alerting on:
            # data volume growth. The DAG getting slower because a warehouse was
            # cold is noise; dbt_run getting slower month over month is a signal.
            sla=timedelta(minutes=30),
        )

        test = BashOperator(
            task_id="dbt_test",
            bash_command=f"cd {DBT_PROJECT_DIR} && dbt test --target prod",
            env=DBT_ENV,
            append_env=True,
            execution_timeout=timedelta(minutes=20),
            # No retries. A failed test is a fact about the data, and running it
            # again three times will produce the same failure while delaying the
            # alert by 35 minutes and burning three warehouse resumes. Retries are
            # for transient failures; a test failure is the opposite of transient.
            retries=0,
        )

        deps >> run >> test

    source_freshness = BashOperator(
        task_id="source_freshness",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt source freshness --target prod",
        env=DBT_ENV,
        append_env=True,
        execution_timeout=timedelta(minutes=10),
        retries=0,
        # Freshness is checked AFTER the load and in PARALLEL with the transform,
        # which looks wrong and is deliberate.
        #
        # Before the load, it would measure the previous run's _loaded_at and pass
        # trivially every night — a check that cannot fail is decoration.
        #
        # Gating the transform on it would mean a stale *source* blocks the
        # rebuild of marts that are already correct. Staleness is a message about
        # an upstream system, not a reason to stop republishing.
        #
        # So: after the load, so it measures this run; parallel to the transform,
        # so it informs without blocking. It fails the DAG (surfacing the alert)
        # while the marts still publish.
        trigger_rule="all_success",
    )

    publish_gate = EmptyOperator(
        task_id="publish_gate",
        # The gate that makes "zero bad-data publications" mean something. It is
        # downstream of dbt_test, so nothing marked as published exists unless the
        # tests passed. all_success is the default and is stated explicitly here
        # because it is the single most important trigger rule in the DAG: an
        # all_done here would let a failed test through and quietly undo the point
        # of having tests.
        trigger_rule="all_success",
    )

    generate_docs = BashOperator(
        task_id="dbt_docs_generate",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt docs generate --target prod",
        env=DBT_ENV,
        append_env=True,
        execution_timeout=timedelta(minutes=10),
        retries=1,
        # Docs are downstream of the gate and failure here is not worth an alert
        # at 03:00 — stale docs are an inconvenience, not bad data. But it must not
        # mark the DAG successful if it fails, hence it stays in the graph rather
        # than being fire-and-forget.
    )

    end = EmptyOperator(task_id="end", trigger_rule="all_success")

    extract = extract_group()
    load = load_group()
    transform = transform_group()

    start >> extract >> load
    load >> [transform, source_freshness]
    transform >> publish_gate >> generate_docs >> end
    source_freshness >> end
