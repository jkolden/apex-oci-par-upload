create or replace package pkg_oci_par as
-- =============================================================================
-- OCI Object Storage pre-authenticated requests (PARs) for browser-direct
-- uploads. File bytes never pass through the database.
-- Based on https://blog.cloudnueva.com/apex-oci-par (CNDEMO_OCI_PRE_AUTH_REQUESTS_PK).
-- =============================================================================

    -- -------------------------------------------------------------------------
    -- CONFIGURE: replace the <...> values before compiling (see README).
    -- -------------------------------------------------------------------------
    -- Object Storage namespace (OCI Console > Tenancy details > Object storage namespace)
    gc_namespace     constant varchar2(100) := '<your_namespace>';
    gc_bucket_name   constant varchar2(100) := '<your_bucket>';
    -- Region endpoint, e.g. https://objectstorage.us-ashburn-1.oraclecloud.com
    gc_base_url      constant varchar2(100) := 'https://objectstorage.<region>.oraclecloud.com';

    -- APEX Web Credential (static ID) of type "OCI Native Authentication" (API signing
    -- key). Used to create PARs; an auth-token DBMS_CLOUD credential cannot sign this call.
    gc_credential    constant varchar2(50)  := 'OCI_NATIVE_CRED';
    -- -------------------------------------------------------------------------

    gc_par_prefix    constant varchar2(25)  := 'APEX_UPLOAD_';

    -- Folder in the bucket for files uploaded from APEX.
    gc_upload_prefix constant varchar2(50)  := 'apex_uploads/';

    -- Generate a pre-authenticated request URL.
    -- p_expiration_unit   [DAY, HOUR, MINUTE, SECOND]
    -- p_expiration_value  Number of p_expiration_unit until the URL expires.
    -- p_access_type       [ObjectRead, ObjectWrite, ObjectReadWrite, AnyObjectWrite, AnyObjectRead, AnyObjectReadWrite]
    -- p_object_name       Object name or prefix the URL has access to.
    -- p_object_listing    [Deny, ListObjects]
    function generate_pre_auth_request(
        p_expiration_unit  in varchar2,
        p_expiration_value in number,
        p_access_type      in varchar2,
        p_object_name      in varchar2 default null,
        p_object_listing   in varchar2 default 'Deny'
    ) return varchar2;

    -- Generate a single-object write PAR so the browser can upload p_file_name
    -- directly to Object Storage under gc_upload_prefix.
    -- p_expiry_minutes must allow for the full upload of a large file.
    procedure get_upload_url(
        p_file_name      in  varchar2,
        p_expiry_minutes in  number default 120,
        p_object_name    out varchar2,
        p_upload_url     out varchar2
    );

end pkg_oci_par;
/
