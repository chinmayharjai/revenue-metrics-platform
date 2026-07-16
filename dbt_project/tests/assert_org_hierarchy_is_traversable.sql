{{ config(severity = 'error', tags = ['data_quality', 'referential_integrity']) }}

/*
    The sales org must have exactly one root and no cycles.

    Both conditions are prerequisites for the recursive CTE in
    sql_showcase/org_hierarchy_recursive_cte.sql, and they fail in opposite,
    equally unhelpful ways:

      - Two roots: the recursion produces two disconnected trees, the rollup
        silently reports a subtree as the whole company, and the number looks
        plausible.
      - A cycle: the recursion never terminates. Snowflake caps it and errors, so
        this one at least fails loudly — but at 03:00, inside a DAG, as a
        cryptic recursion-limit message rather than "your org data has a loop".

    Catching both here means the showcase query and dim_customer's flattened chain
    can assume a well-formed tree instead of defending against it.
*/

-- `recursive` is optional in Snowflake, which infers it from the self-reference in
-- `reachable`. Stated explicitly anyway: a reader scanning this file should not
-- have to find the recursive branch to know the CTE recurses, and relying on
-- inference makes the query silently dialect-specific.
with recursive employees as (

    select * from {{ ref('stg_employees') }}

),

root_count as (

    select count(*) as n_roots
    from employees
    where manager_id is null

),

-- Walk the tree from the root. Any employee not reached is either in a cycle or
-- hanging off a manager that does not exist.
reachable as (

    select
        employee_id,
        manager_id,
        1 as depth
    from employees
    where manager_id is null

    union all

    select
        employees.employee_id,
        employees.manager_id,
        reachable.depth + 1 as depth
    from employees
    inner join reachable
        on employees.manager_id = reachable.employee_id
    where reachable.depth < 20
    -- Depth guard. Without it a cycle spins until Snowflake's recursion limit
    -- aborts the run. With it, the cycle shows up as unreachable rows below and
    -- reports itself as a data problem.

),

unreachable as (

    select employees.employee_id, employees.manager_id
    from employees
    left join reachable
        on employees.employee_id = reachable.employee_id
    where reachable.employee_id is null

),

failures as (

    select
        'expected exactly 1 org root, found ' || n_roots::varchar as failure_reason,
        null as employee_id
    from root_count
    where n_roots != 1

    union all

    select
        'employee unreachable from org root (cycle or dangling manager_id)' as failure_reason,
        employee_id
    from unreachable

    union all

    -- The flattened chain in dim_customer walks exactly four levels (AE -> manager
    -- -> director -> VP -> root). If the org ever grew a level, that flattening
    -- would truncate silently and every report rolling up by VP would quietly
    -- exclude a branch. Fail here instead.
    select
        'org depth exceeds the 5 levels dim_customer flattens' as failure_reason,
        employee_id
    from reachable
    where depth > 5

)

select * from failures
