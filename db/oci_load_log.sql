-- =============================================================================
-- OCI_LOAD_LOG
-- =============================================================================
-- One row per CSV load submitted by pkg_oci_load.submit_load.
-- Status flow: QUEUED -> RUNNING -> SUCCESS | ERROR
-- =============================================================================

CREATE TABLE oci_load_log (
    load_id         NUMBER GENERATED ALWAYS AS IDENTITY,
    object_name     VARCHAR2(1000)  NOT NULL,
    target_table    VARCHAR2(128)   NOT NULL,
    status          VARCHAR2(20)    DEFAULT 'QUEUED',
    rows_loaded     NUMBER,
    rows_rejected   NUMBER,
    operation_id    NUMBER,
    logfile_table   VARCHAR2(128),
    badfile_table   VARCHAR2(128),
    error_message   VARCHAR2(4000),
    submitted_by    VARCHAR2(255),
    submitted_ts    TIMESTAMP(6)    DEFAULT SYSTIMESTAMP,
    started_ts      TIMESTAMP(6),
    completed_ts    TIMESTAMP(6),
    CONSTRAINT oci_load_log_pk PRIMARY KEY (load_id)
);

CREATE INDEX oci_load_log_n1 ON oci_load_log (submitted_ts);
