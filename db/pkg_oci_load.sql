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

    -- -------------------------------------------------------------------------
    -- OPTIONAL: automatic PGP decryption (docs/pgp-decrypt-setup.md). The OCI Function
    -- in oci-function/pgp-decrypt turns an encrypted upload (<name>.gz.pgp) into a
    -- short-lived plaintext staging object that run_load loads and then deletes.
    -- -------------------------------------------------------------------------
    -- "fnproject.io/fn/invokeEndpoint" from: fn inspect function <app> pgp-decrypt
    gc_fn_invoke_url      constant varchar2(500) := '<https://....functions.oci.oraclecloud.com/20181201/functions/ocid1.fnfunc..../actions/invoke>';
    -- DBMS_CLOUD credential that signs requests with an OCI API key (auth tokens can't call Functions).
    gc_fn_credential      constant varchar2(128) := 'OCI_API_KEY_CRED';
    gc_staging_prefix     constant varchar2(50)  := 'apex_staging/';

    -- Queue a background load of p_object_name into gc_target_table.
    -- Returns the oci_load_log.load_id to poll for status.
    function submit_load(p_object_name in varchar2) return number;

    -- Run by the scheduler job created in submit_load. Objects ending in .pgp are
    -- decrypted to a staging object first (status DECRYPTING), loaded, then the
    -- staging object is deleted.
    procedure run_load(p_load_id in number);

    -- Call the pgp-decrypt function for p_object_name (e.g. apex_uploads/x.csv.gz.pgp).
    -- Returns the plaintext staging object name (apex_staging/x.csv); the caller deletes it.
    function decrypt_to_staging(p_object_name in varchar2) return varchar2;

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
