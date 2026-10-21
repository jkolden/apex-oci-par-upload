-- =============================================================================
-- LANDING TABLE: LANDING_APEX_UPLOAD
-- =============================================================================
-- Target of pkg_oci_load. COPY_DATA maps CSV fields to columns by position, so
-- the column order MUST match the CSV header from tools/make_test_csv.py:
--   INVOICE_ID,INVOICE_NUM,VENDOR_NUM,VENDOR_NAME,INVOICE_DATE,GL_DATE,
--   INVOICE_AMOUNT,CURRENCY_CODE,PAYMENT_TERMS,DESCRIPTION,CREATED_TS
-- Dates are YYYY-MM-DD, timestamps YYYY-MM-DD HH24:MI:SS (see pkg_oci_load format).
-- =============================================================================

CREATE TABLE landing_apex_upload (
    invoice_id      NUMBER,
    invoice_num     VARCHAR2(50),
    vendor_num      VARCHAR2(30),
    vendor_name     VARCHAR2(240),
    invoice_date    DATE,
    gl_date         DATE,
    invoice_amount  NUMBER(14,2),
    currency_code   VARCHAR2(3),
    payment_terms   VARCHAR2(30),
    description     VARCHAR2(500),
    created_ts      TIMESTAMP(6)
);
