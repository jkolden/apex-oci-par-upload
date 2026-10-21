-- =============================================================================
-- T_KPI_ROW / T_KPI_TAB
-- =============================================================================
-- Row type returned by get_invoice_kpis and read by the Cards region on the
-- Loaded Records page (select * from table(get_invoice_kpis(...)) order by sort_order).
-- Skip this script if the types already exist in your schema.
-- =============================================================================

create or replace type t_kpi_row as object (
    kpi_key     varchar2(30),
    title       varchar2(100),
    display     varchar2(100),
    icon_class  varchar2(100),
    css_class   varchar2(200),
    sort_order  number
);
/

create or replace type t_kpi_tab as table of t_kpi_row;
/
