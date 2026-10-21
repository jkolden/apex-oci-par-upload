-- =============================================================================
-- Install all database objects, in dependency order.
-- Run from SQLcl or SQL*Plus in the APEX workspace's parsing schema:
--     cd db
--     sql <user>@<tns_alias> @install.sql
-- In APEX SQL Workshop (which can't run @ scripts), run the files below one by
-- one in this order instead.
--
-- Edit the CONFIGURE sections of pkg_oci_par.sql and pkg_oci_load.sql first.
-- =============================================================================
set define off

prompt == Types
@t_kpi_types.sql

prompt == Tables
@landing_apex_upload.sql
@oci_load_log.sql

prompt == Packages
@pkg_oci_par.sql
@pkg_oci_par.plb
@pkg_oci_load.sql
@pkg_oci_load.plb

prompt == KPI function
@get_invoice_kpis.sql

prompt == Invalid objects (should be none)
select object_name, object_type
from   user_objects
where  status = 'INVALID'
and    object_name in ('PKG_OCI_PAR', 'PKG_OCI_LOAD', 'GET_INVOICE_KPIS', 'T_KPI_ROW', 'T_KPI_TAB');
