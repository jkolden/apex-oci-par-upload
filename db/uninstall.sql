-- =============================================================================
-- Remove all database objects created by install.sql.
-- Does NOT delete files in the bucket or the credentials.
-- Leave out the type drops if other code uses T_KPI_ROW / T_KPI_TAB.
-- =============================================================================

drop function get_invoice_kpis;
drop package pkg_oci_load;
drop package pkg_oci_par;
drop table oci_load_log purge;
drop table landing_apex_upload purge;
drop type t_kpi_tab;
drop type t_kpi_row;

-- COPY$n_LOG / COPY$n_BAD tables left by DBMS_CLOUD.COPY_DATA
begin
    dbms_cloud.delete_all_operations('COPY');
end;
/
