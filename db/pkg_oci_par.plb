create or replace package body pkg_oci_par as

    -- =========================================================================
    -- GENERATE PRE-AUTHENTICATED REQUEST
    -- =========================================================================
    -- Calls the OCI CreatePreauthenticatedRequest API and returns the full PAR URL,
    -- e.g. https://objectstorage.<region>.oraclecloud.com/p/<token>/n/<namespace>/b/<bucket>/o/<object>
    -- =========================================================================

    function generate_pre_auth_request(
        p_expiration_unit  in varchar2,
        p_expiration_value in number,
        p_access_type      in varchar2,
        p_object_name      in varchar2 default null,
        p_object_listing   in varchar2 default 'Deny'
    ) return varchar2 is
        l_request_url   varchar2(1000);
        l_request_json  clob;
        l_response_json clob;
        l_expires_str   varchar2(100);
        l_par_name      varchar2(100);
    begin
        -- Expiration time in UTC, ISO 8601
        l_expires_str := to_char(
            systimestamp at time zone 'UTC' + numtodsinterval(p_expiration_value, p_expiration_unit),
            'yyyy-mm-dd"T"hh24:mi:ss"Z"'
        );

        l_par_name    := gc_par_prefix || p_access_type || '_' || l_expires_str;
        l_request_url := gc_base_url || '/n/' || gc_namespace || '/b/' || gc_bucket_name || '/p/';

        l_request_json := '{'
            || '"accessType":' || apex_json.stringify(p_access_type) || ','
            || '"name":'       || apex_json.stringify(l_par_name) || ','
            || case
                   when p_object_name is not null
                   then '"objectName":' || apex_json.stringify(p_object_name) || ','
               end
            || '"bucketListingAction":' || apex_json.stringify(p_object_listing) || ','
            || '"timeExpires":'         || apex_json.stringify(l_expires_str)
            || '}';

        l_response_json := apex_web_service.make_rest_request(
            p_url                  => l_request_url,
            p_http_method          => 'POST',
            p_body                 => l_request_json,
            p_credential_static_id => gc_credential
        );

        if apex_web_service.g_status_code = 200 then
            apex_debug.info('generate_pre_auth_request: created %s', l_par_name);
            return gc_base_url || json_object_t.parse(l_response_json).get_string('accessUri');
        end if;

        apex_debug.error('generate_pre_auth_request failed: status=%s url=%s response=%s',
                         apex_web_service.g_status_code, l_request_url,
                         dbms_lob.substr(l_response_json, 3000, 1));
        raise_application_error(-20111, 'Unable to create pre-authenticated request (HTTP '
                                        || apex_web_service.g_status_code || ').');
    exception
        when others then
            apex_debug.error('generate_pre_auth_request failed: %s', sqlerrm);
            raise;
    end generate_pre_auth_request;


    -- =========================================================================
    -- UPLOAD URL FOR APEX
    -- =========================================================================
    -- Object name is timestamp-prefixed so repeat uploads of the same file
    -- don't overwrite each other.
    -- =========================================================================

    procedure get_upload_url(
        p_file_name      in  varchar2,
        p_expiry_minutes in  number default 120,
        p_object_name    out varchar2,
        p_upload_url     out varchar2
    ) is
    begin
        p_object_name := gc_upload_prefix
            || to_char(systimestamp at time zone 'UTC', 'yyyymmdd_hh24miss') || '_'
            || substr(regexp_replace(p_file_name, '[^A-Za-z0-9._-]', '_'), 1, 200);

        p_upload_url := generate_pre_auth_request(
            p_expiration_unit  => 'MINUTE',
            p_expiration_value => p_expiry_minutes,
            p_access_type      => 'ObjectWrite',
            p_object_name      => p_object_name
        );
    end get_upload_url;

end pkg_oci_par;
/
