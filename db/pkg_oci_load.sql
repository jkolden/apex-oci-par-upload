create or replace package pkg_oci_load as
-- =============================================================================
-- Loads CSV files uploaded through pkg_oci_par into the database with DBMS_CLOUD.COPY_DATA.
-- Each load runs as a one-off scheduler job so multi-GB files don't hit the
-- APEX request timeout. Progress is recorded in oci_load_log.
-- =============================================================================

    -- -------------------------------------------------------------------------
    -- CONFIGURE: DBMS_CLOUD credential (user_credentials) with read access to the
    -- bucket. An auth-token credential is fine for COPY_DATA and LIST_OBJECTS.
    -- -------------------------------------------------------------------------
    gc_credential   constant varchar2(128) := 'OBJ_STORE_CRED';
    gc_bucket_uri   constant varchar2(200) := pkg_oci_par.gc_base_url
                                              || '/n/' || pkg_oci_par.gc_namespace
                                              || '/b/' || pkg_oci_par.gc_bucket_name || '/o/';

    -- Landing table every upload loads into (landing_apex_upload.sql). Truncated before each load.
    gc_target_table constant varchar2(128) := 'LANDING_APEX_UPLOAD';

    -- Bad rows tolerated before COPY_DATA fails the load.
    gc_reject_limit constant varchar2(10)  := '100';

    -- Queue a background load of p_object_name into gc_target_table.
    -- Returns the oci_load_log.load_id to poll for status.
    function submit_load(p_object_name in varchar2) return number;

    -- Run by the scheduler job created in submit_load.
    procedure run_load(p_load_id in number);

    -- Called before reading a load's status. If the load is still QUEUED/RUNNING but its
    -- scheduler job has gone (e.g. the job failed before run_load could record it),
    -- marks the load ERROR with the scheduler's error text.
    procedure check_job(p_load_id in number);

    -- Record a browser-side upload failure in oci_load_log (status UPLOAD_FAILED).
    -- p_object_name is null when the failure happened before a PAR was issued.
    procedure log_upload_failure(
        p_file_name   in varchar2,
        p_object_name in varchar2,
        p_error       in varchar2
    );

    -- For SQL callers (report queries), since package constants can't be referenced in SQL.
    function credential_name return varchar2;   -- gc_credential
    function uploads_uri return varchar2;       -- bucket URI of the upload folder

    -- SQL for the Rejected Rows dialog (columns LINE_NO, RECORD).
    -- p_kind: BAD = the rejected CSV lines; LOG = one row per rejection, where LINE_NO is
    -- the row in the file (header = row 1) and RECORD is "<column> - <ORA error>".
    function rejects_query(p_load_id in number, p_kind in varchar2) return varchar2;

end pkg_oci_load;
/
