create or replace package body pkg_oci_load as

    -- =========================================================================
    -- SUBMIT LOAD
    -- =========================================================================

    function submit_load(p_object_name in varchar2) return number is
        l_load_id   number;
        l_error_msg varchar2(4000);
    begin
        insert into oci_load_log (object_name, target_table, status, submitted_by)
        values (p_object_name, gc_target_table, 'QUEUED',
                coalesce(sys_context('APEX$SESSION', 'APP_USER'), user))
        returning load_id into l_load_id;

        -- create_job commits, which also commits the log row
        dbms_scheduler.create_job(
            job_name   => 'OCI_LOAD_' || l_load_id,
            job_type   => 'PLSQL_BLOCK',
            job_action => 'begin pkg_oci_load.run_load(' || l_load_id || '); end;',
            enabled    => true,
            auto_drop  => true
        );

        return l_load_id;
    exception
        when others then
            -- Don't leave a QUEUED row behind if the job couldn't be created
            if l_load_id is not null then
                l_error_msg := substr(sqlerrm, 1, 4000);
                update oci_load_log
                set    status = 'ERROR', error_message = l_error_msg, completed_ts = systimestamp
                where  load_id = l_load_id;
                commit;
            end if;
            raise;
    end submit_load;


    -- =========================================================================
    -- RUN LOAD
    -- =========================================================================
    -- Flow: TRUNCATE target -> COPY_DATA -> record counts from user_load_operations
    -- =========================================================================

    -- =========================================================================
    -- PGP DECRYPTION (OCI Function)
    -- =========================================================================
    -- The function streams the encrypted object through gpg and gunzip into a
    -- plaintext staging object, using a private key it reads from OCI Vault.
    -- =========================================================================

    function decrypt_to_staging(p_object_name in varchar2) return varchar2 is
        l_target varchar2(1000);
        l_resp   dbms_cloud_types.resp;
        l_status number;
        l_text   clob;
    begin
        l_target := gc_staging_prefix
            || regexp_replace(substr(p_object_name, length(pkg_oci_par.gc_upload_prefix) + 1),
                              '(\.gz)?\.pgp$', '', 1, 1, 'i');

        -- Large files can take a few minutes to decrypt (the function allows 300 s).
        utl_http.set_transfer_timeout(300);

        l_resp := dbms_cloud.send_request(
            credential_name => gc_fn_credential,
            uri             => gc_fn_invoke_url,
            method          => dbms_cloud.method_post,
            body            => utl_raw.cast_to_raw(json_object(
                                   'namespace' value pkg_oci_par.gc_namespace,
                                   'bucket'    value pkg_oci_par.gc_bucket_name,
                                   'object'    value p_object_name,
                                   'target'    value l_target))
        );

        -- The function reports failures as {"error": ...}; depending on how OCI relays the
        -- function's status code this can arrive with HTTP 200, so check both.
        l_status := dbms_cloud.get_response_status_code(l_resp);
        l_text   := dbms_cloud.get_response_text(l_resp);
        if l_status <> 200 or dbms_lob.instr(l_text, '"error"') > 0 then
            raise_application_error(-20112, 'PGP decryption failed (HTTP ' || l_status || '): '
                || dbms_lob.substr(l_text, 2000, 1));
        end if;
        return l_target;
    end decrypt_to_staging;

    procedure delete_staging(p_object_name in varchar2) is
    begin
        dbms_cloud.delete_object(credential_name => gc_credential,
                                 object_uri      => gc_bucket_uri || p_object_name);
    exception
        when others then
            null;   -- the bucket lifecycle rule removes anything left behind
    end delete_staging;


    procedure run_load(p_load_id in number) is
        l_object_name   oci_load_log.object_name%type;
        l_source        varchar2(1000);
        l_staging       varchar2(1000);
        l_encrypted     boolean;
        l_status        oci_load_log.status%type;
        l_operation_id  number;
        l_rows_loaded   number;
        l_rejected      number := 0;
        l_logfile_table varchar2(128);
        l_badfile_table varchar2(128);
        l_error_msg     varchar2(4000);
    begin
        select object_name into l_object_name from oci_load_log where load_id = p_load_id;
        l_encrypted := lower(l_object_name) like '%.pgp';

        l_status := case when l_encrypted then 'DECRYPTING' else 'RUNNING' end;
        update oci_load_log
        set    status = l_status, started_ts = systimestamp
        where  load_id = p_load_id;
        commit;

        l_source := l_object_name;
        if l_encrypted then
            l_staging := decrypt_to_staging(l_object_name);
            l_source  := l_staging;
            update oci_load_log set status = 'RUNNING' where load_id = p_load_id;
            commit;
        end if;

        execute immediate 'truncate table ' || dbms_assert.simple_sql_name(gc_target_table);

        dbms_cloud.copy_data(
            table_name      => gc_target_table,
            credential_name => gc_credential,
            file_uri_list   => gc_bucket_uri || l_source,
            format          => json_object(
                                 'type'                 value 'csv',
                                 'skipheaders'          value '1',
                                 'blankasnull'          value 'true',
                                 'ignoremissingcolumns' value 'true',
                                 'dateformat'           value 'YYYY-MM-DD',
                                 'timestampformat'      value 'YYYY-MM-DD HH24:MI:SS',
                                 'rejectlimit'          value gc_reject_limit
                               ),
            operation_id    => l_operation_id
        );

        select rows_loaded, logfile_table, badfile_table
        into   l_rows_loaded, l_logfile_table, l_badfile_table
        from   user_load_operations
        where  id = l_operation_id;

        -- Bad file table is only populated when rows were rejected
        if l_badfile_table is not null then
            begin
                execute immediate 'select count(*) from ' || dbms_assert.simple_sql_name(l_badfile_table)
                into l_rejected;
            exception
                when others then
                    l_rejected := 0;
            end;
        end if;

        update oci_load_log
        set    status        = 'SUCCESS',
               operation_id  = l_operation_id,
               rows_loaded   = l_rows_loaded,
               rows_rejected = l_rejected,
               logfile_table = l_logfile_table,
               badfile_table = l_badfile_table,
               completed_ts  = systimestamp
        where  load_id = p_load_id;
        commit;

        if l_staging is not null then
            delete_staging(l_staging);   -- plaintext copy is only needed for the load
        end if;
    exception
        when others then
            l_error_msg := substr(sqlerrm || chr(10) || dbms_utility.format_error_backtrace, 1, 4000);
            if l_staging is not null then
                delete_staging(l_staging);
            end if;
            update oci_load_log
            set    status        = 'ERROR',
                   operation_id  = l_operation_id,
                   error_message = l_error_msg,
                   completed_ts  = systimestamp
            where  load_id = p_load_id;
            commit;
            raise;
    end run_load;


    -- =========================================================================
    -- CHECK JOB
    -- =========================================================================
    -- run_load commits its final status before the job ends, so "job gone but
    -- status still QUEUED/RUNNING" can only mean the job died without recording it.
    -- =========================================================================

    procedure check_job(p_load_id in number) is
        l_job    varchar2(30) := 'OCI_LOAD_' || p_load_id;
        l_status oci_load_log.status%type;
        l_exists number;
        l_errors varchar2(4000);
    begin
        select status into l_status from oci_load_log where load_id = p_load_id;
        if l_status not in ('QUEUED', 'DECRYPTING', 'RUNNING') then
            return;
        end if;

        select count(*) into l_exists from user_scheduler_jobs where job_name = l_job;
        if l_exists > 0 then
            return;   -- still waiting to start, or running
        end if;

        select max(substr(errors, 1, 4000)) keep (dense_rank last order by log_date)
        into   l_errors
        from   user_scheduler_job_run_details
        where  job_name = l_job;

        update oci_load_log
        set    status        = 'ERROR',
               error_message = nvl(l_errors, 'Load job ended without recording a result.'),
               completed_ts  = systimestamp
        where  load_id = p_load_id
        and    status in ('QUEUED', 'DECRYPTING', 'RUNNING');
        commit;
    exception
        when no_data_found then
            null;
    end check_job;


    -- =========================================================================
    -- LOG UPLOAD FAILURE
    -- =========================================================================

    procedure log_upload_failure(
        p_file_name   in varchar2,
        p_object_name in varchar2,
        p_error       in varchar2
    ) is
    begin
        insert into oci_load_log (
            object_name, target_table, status, error_message,
            submitted_by, started_ts, completed_ts
        ) values (
            coalesce(p_object_name, p_file_name),
            case when lower(p_file_name) like '%.csv' then gc_target_table else '-' end,
            'UPLOAD_FAILED',
            substr(p_error, 1, 4000),
            coalesce(sys_context('APEX$SESSION', 'APP_USER'), user),
            systimestamp,
            systimestamp
        );
    end log_upload_failure;


    -- =========================================================================
    -- SQL HELPERS
    -- =========================================================================

    function credential_name return varchar2 is
    begin
        return gc_credential;
    end credential_name;

    function uploads_uri return varchar2 is
    begin
        return gc_bucket_uri || pkg_oci_par.gc_upload_prefix;
    end uploads_uri;


    -- =========================================================================
    -- REJECTED ROWS QUERY
    -- =========================================================================
    -- Used by "Function Body returning SQL Query" regions. Always returns the same
    -- two columns so APEX can parse it at design time (when p_load_id is null).
    -- =========================================================================

    function rejects_query(p_load_id in number, p_kind in varchar2) return varchar2 is
        lc_empty constant varchar2(100) := 'select 1 as line_no, null as record from dual where 1 = 0';
        l_table  varchar2(128);
        l_exists number;
    begin
        select case p_kind when 'BAD' then badfile_table else logfile_table end
        into   l_table
        from   oci_load_log
        where  load_id = p_load_id;

        if l_table is null then
            return lc_empty;
        end if;

        -- COPY$ tables are dropped by dbms_cloud.delete_all_operations
        select count(*) into l_exists from user_tables where table_name = l_table;
        if l_exists = 0 then
            return q'[select 1 as line_no,
                             'Details are no longer available: the COPY$ tables for this load were dropped.' as record
                      from dual]';
        end if;

        if p_kind = 'BAD' then
            return 'select rownum as line_no, record from ' || dbms_assert.simple_sql_name(l_table);
        end if;

        -- The log has an "error processing column X in row N ..." line followed by its
        -- ORA- line. Pair them on the log's read order.
        return q'[select to_number(regexp_substr(err, 'in row (\d+)', 1, 1, null, 1)) as line_no,
                         regexp_substr(err, 'column (\S+)', 1, 1, null, 1) || ' - ' || ora as record
                  from (select record as err,
                               lead(record) over (order by rn) as ora
                        from (select record, rownum as rn from ]'
            || dbms_assert.simple_sql_name(l_table) || q'[))
                  where err like 'error processing column%'
                  order by line_no]';
    exception
        when no_data_found then
            return lc_empty;
    end rejects_query;

end pkg_oci_load;
/
