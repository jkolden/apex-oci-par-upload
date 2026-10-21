# APEX large-file upload to OCI Object Storage

Upload multi-GB files from an Oracle APEX page **straight to OCI Object Storage**, then load
CSVs into Autonomous Database automatically, with live progress, a load audit log, and
rejected-row drill-down.

The file never passes through APEX or the database on the way up. APEX only issues a
short-lived, single-object [pre-authenticated request](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/usingpreauthenticatedrequests.htm)
(PAR). The browser uploads to it directly, in parallel parts for large files. When a CSV
lands, a background job runs `DBMS_CLOUD.COPY_DATA` from the bucket into a table.

> **Credit:** the pre-authenticated request code builds on Jon Dixon's
> [Using OCI Pre-Authenticated Requests with APEX](https://blog.cloudnueva.com/apex-oci-par)
> (Cloud Nueva). Thanks, Jon!

![PAR Upload page](docs/images/par-upload-page.png)

## Results from testing

| Test | Result |
|---|---|
| 856 MB CSV, 6.5 million rows | Upload 5 min 41 s (2.5 MB/s, limited by the uploader's connection) · **load into ATP 23 s** · 0 rejected |
| 1 GB binary file | Multipart upload, 16 × 64 MB parts, 7 min 6 s |
| 1,000-row CSV with 3 bad rows | 997 loaded, 3 rejected and shown with the reason for each |

Upload time depends on the user's connection. Once a file is in the bucket, the database
loads millions of rows in seconds.

## How it works

```mermaid
sequenceDiagram
    participant B as Browser
    participant A as APEX (pkg_oci_par / pkg_oci_load)
    participant O as OCI Object Storage
    participant J as Scheduler job (COPY_DATA)

    B->>A: GET_UPLOAD_URL (file name)
    A->>O: Create PAR (signed with OCI API key)
    O-->>A: PAR URL (write one object, expires in 2 h)
    A-->>B: PAR URL
    B->>O: PUT file (or multipart: start, parts ×4 parallel, commit)
    B->>A: START_LOAD (CSV only)
    A->>J: dbms_scheduler.create_job
    J->>O: COPY_DATA reads the CSV
    J->>A: oci_load_log: rows loaded / rejected
    loop every 3 s
        B->>A: LOAD_STATUS
    end
```

**Features**

- Drag-and-drop upload with a two-step tracker (upload → load) and a progress bar
- Files over 128 MB upload as 64 MB parts, 4 in parallel, each retried up to 3 times;
  a failed upload is aborted so no partial object is left
- CSVs load automatically in a background job, so long loads don't hit APEX request timeouts
- `oci_load_log` audits every load and every failed upload; stuck or dead jobs are detected
- Rejected rows are kept, with a dialog showing each bad line and why it was rejected
- Loaded Records page with KPI cards that follow the report's filters
- Test data generator for files of any size, with deliberate bad rows if you want them

## Repository layout

```
apex-app/                  APEX application, APEXlang format (APEX 26.1)
  pages/                   4 PAR Upload · 5 Rejected Rows (modal) · 6 Loaded Records · 9999 Login
  shared-components/static-files/par_upload.js, par_upload.css
db/
  install.sql              runs everything below in order
  pkg_oci_par.sql/.plb     creates PARs (configure namespace, bucket, region, credential here)
  pkg_oci_load.sql/.plb    background CSV load, status, rejects (configure DBMS_CLOUD credential here)
  oci_load_log.sql         load / upload audit table
  landing_apex_upload.sql  target table (sample AP-invoice layout)
  t_kpi_types.sql          row type for the KPI cards
  get_invoice_kpis.sql     KPIs for the Loaded Records page
  uninstall.sql
tools/make_test_csv.py     test CSV generator
docs/manual-page-build.md  build the pages by hand instead of importing
```

## Prerequisites

- **Oracle Autonomous Database** with APEX. Tested on APEX **26.1**; the export uses
  the APEXlang format, which needs 26.1 or later. The database code is plain PL/SQL and
  `DBMS_CLOUD`, so it also works on older versions if you
  [build the pages by hand](docs/manual-page-build.md).
- An **OCI Object Storage bucket**.
- An **OCI IAM user with an API signing key**. The PAR call must be signed, so an auth
  token won't do.
- The schema needs **`CREATE JOB`**. Autonomous Database schemas usually have it.
- Python 3.9+ to generate test data (optional).

## Setup

### 1. OCI: API key and policy

1. Pick an IAM user (ideally a dedicated service user) and add an **API key**: Profile →
   Tokens and keys → Add API key → Generate API key pair → **download the private key**.
   Note the user OCID, tenancy OCID and fingerprint from the configuration preview.
2. Allow that user's group to manage objects in the bucket. This includes `PAR_MANAGE`:

   ```
   Allow group <group> to manage objects in compartment <compartment>
     where target.bucket.name = '<your_bucket>'
   ```

### 2. Credentials

**APEX Web Credential, used to create PARs.** In the workspace: App Builder → Workspace
Utilities → Web Credentials → Create.

| Field | Value |
|---|---|
| Name / Static ID | `OCI_NATIVE_CRED` (or change `pkg_oci_par.gc_credential`) |
| Authentication Type | OCI Native Authentication |
| OCI User ID / Tenancy ID / Fingerprint | from step 1 |
| OCI Private Key | the whole `.pem` file, including the `BEGIN`/`END` lines, with no passphrase |
| Valid for URLs | `https://objectstorage.<region>.oraclecloud.com/` |

**DBMS_CLOUD credential, used by `COPY_DATA` and `LIST_OBJECTS`.** Run as the parsing schema:

```sql
begin
  dbms_cloud.create_credential(
    credential_name => 'OBJ_STORE_CRED',          -- or change pkg_oci_load.gc_credential
    username        => '<oci_username>',
    password        => '<auth_token>');           -- Profile > Tokens and keys > Auth tokens
end;
/
```

An API-key DBMS_CLOUD credential (`user_ocid`, `tenancy_ocid`, `private_key`,
`fingerprint`) works too.

### 3. Install the database objects

Edit the **CONFIGURE** sections first:

| File | Constant | Example |
|---|---|---|
| `db/pkg_oci_par.sql` | `gc_namespace` | your Object Storage namespace (Tenancy details) |
| | `gc_bucket_name` | `my-upload-bucket` |
| | `gc_base_url` | `https://objectstorage.us-ashburn-1.oraclecloud.com` |
| | `gc_credential` | `OCI_NATIVE_CRED` (the Web Credential static ID) |
| `db/pkg_oci_load.sql` | `gc_credential` | `OBJ_STORE_CRED` (the DBMS_CLOUD credential) |

Then, from SQLcl or SQL*Plus:

```
cd db
sql <user>@<tns_alias> @install.sql
```

Or, in SQL Workshop → SQL Scripts, run the files in the order listed in `install.sql`.
If you already have `T_KPI_ROW`/`T_KPI_TAB`, skip `t_kpi_types.sql`.

**Smoke test** (SQL Workshop → SQL Commands; the Web Credential needs an APEX session):

```sql
declare
  l_obj varchar2(1000);
  l_url varchar2(2000);
begin
  pkg_oci_par.get_upload_url('test.txt', 15, l_obj, l_url);
  dbms_output.put_line(l_url);
end;
```

Then `curl -i -X PUT --data-binary @test.txt "<url>"` should return `HTTP/1.1 200 OK`.

### 4. Install the APEX app

`apex-app/` is an APEXlang export (`.apx` files). Import it into your workspace with
APEX 26.1+ tooling: SQLcl 26.1.2 or later, or the Oracle SQL Developer extension for VS
Code. Follow Oracle's APEXlang documentation for the import command for your version.
For reference, this is how an app is exported in this format:

```
apex export -applicationid <id> -exptype APEXLANG -split -dir <parent-dir>
```

Notes:

- `deployments/default.json` sets application ID **157**. Change it if that ID is taken.
- The app uses **Oracle APEX Accounts** sign-in. Create a workspace user, or switch the
  authentication scheme to your own.
- After importing, regenerate the session state protection salt: Shared Components →
  Security Attributes → Session State Protection.
- The credentials from step 2 are workspace components and aren't part of the export.

If you can't import the APEXlang format, [build the three pages by hand](docs/manual-page-build.md).

## How to use

1. Open **PAR Upload**. Drag a file onto the drop zone or click to browse, then click **Upload**.
2. **Upload to Object Storage** fills the progress bar. Large files go up in parts; the
   status line shows MB sent and, when done, the time and MB/s.
3. For a `.csv`, **Load into ATP** starts automatically and the bar animates while
   the job runs. The status line then shows rows loaded and rejected, plus the total time.
   Other file types only upload.
4. **Load History** lists every load. Click the **Rows Rejected** number to see each
   rejected line and its reason, for example `INVOICE_DATE - ORA-01843: not a valid month`.
5. **Loaded Records** shows the table in an Interactive Report, with KPI cards (invoices,
   total spend, average and largest invoice, vendors, days to GL) that follow its filters.

### Test data

```bash
python tools/make_test_csv.py --rows 1000 --bad 3      # quick check: 3 rows will be rejected
python tools/make_test_csv.py --size-mb 1024           # ~1 GB, ~7.8 M rows
```

Files are written to your Downloads folder. The script prints the expected row count and
amount total so you can reconcile:

```sql
select count(*), sum(invoice_amount) from landing_apex_upload;
```

### Loading your own CSV layout

1. Change `db/landing_apex_upload.sql` to your columns, **in the same order as the CSV**.
   `COPY_DATA` maps fields by position.
2. Adjust `dateformat`/`timestampformat` in `pkg_oci_load.run_load` if your dates differ.
3. Change or remove `get_invoice_kpis` and the Loaded Records page to suit.

Each load **truncates** the target table first, like a landing table. To append instead,
remove the `truncate` in `run_load`.

## Configuration reference

| Setting | Where | Default |
|---|---|---|
| PAR lifetime | `pkg_oci_par.get_upload_url` `p_expiry_minutes` | 120 min |
| Upload folder | `pkg_oci_par.gc_upload_prefix` | `apex_uploads/` |
| Target table | `pkg_oci_load.gc_target_table` | `LANDING_APEX_UPLOAD` |
| Bad rows allowed before the load fails | `pkg_oci_load.gc_reject_limit` | 100 |
| Part size / multipart threshold / parallel parts / retries | top of `par_upload.js` | 64 MB / 128 MB / 4 / 3 |
| Status poll interval / give-up time | top of `par_upload.js` | 3 s / 60 min |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ORA-20111 ... (HTTP 401)` from GET_UPLOAD_URL | Web Credential key, fingerprint or OCIDs are wrong, or the API key was deleted |
| `ORA-20111 ... (HTTP 404)` or `(HTTP 403)` | The IAM user lacks `manage objects` / `PAR_MANAGE` on the bucket, or the namespace or bucket name is wrong |
| `PUT failed: network error` with no HTTP status | Connectivity or CORS. OCI returns permissive CORS headers for PAR requests, so this is usually the network or an expired PAR |
| `... is not a function` in the browser console | The browser is using a cached old `par_upload.js`. Bump `?v=N` on the page's File URL |
| Load stays QUEUED | The scheduler job couldn't start (check `CREATE JOB`). The page's status check marks dead jobs as ERROR |
| Rejected Rows says "no longer available" | The `COPY$n_LOG`/`COPY$n_BAD` tables were dropped (`dbms_cloud.delete_all_operations`) |

Where errors are recorded:

```sql
-- Loads and failed uploads
select * from oci_load_log order by load_id desc;

-- Scheduler outcomes
select job_name, status, errors, actual_start_date
from user_scheduler_job_run_details
where job_name like 'OCI_LOAD_%'
order by actual_start_date desc;

-- PAR creation errors
select message_timestamp, message
from apex_debug_messages
where message like 'generate_pre_auth_request%'
order by message_timestamp desc;
```

## Security notes

- A PAR lets **anyone holding the URL write that one object** until it expires. It's issued
  only to a signed-in APEX session, for one timestamped object name, and expires after
  2 hours by default. Shorten `p_expiry_minutes` if your files are small.
- Uploaded files aren't scanned. Treat the upload folder as untrusted input.
- Use a dedicated IAM user whose policy covers only this bucket.
- The **Truncate** button on Loaded Records deletes all loaded rows. Remove it or protect
  it with an authorization scheme outside of demos.
- `COPY$n_LOG`/`COPY$n_BAD` tables accumulate. Clean them up periodically with
  `dbms_cloud.delete_all_operations('COPY')`.

## License

[MIT](LICENSE)
