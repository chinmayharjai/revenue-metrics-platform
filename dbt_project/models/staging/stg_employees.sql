with source as (

    select * from {{ source('crm', 'employees') }}

),

renamed as (

    select
        employee_id,

        -- NULL manager_id identifies the single org root. This is meaningful, not
        -- missing: the recursive CTE in sql_showcase/org_hierarchy_recursive_cte.sql
        -- anchors on exactly this condition. The not_null test is therefore on
        -- employee_id only — a not_null on manager_id would fail on the one row
        -- that is supposed to look like that.
        manager_id,
        manager_id is null as is_org_root,

        full_name,
        title,
        region,

        _source_file,
        _loaded_at

    from source

)

select * from renamed
