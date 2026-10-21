# Building the pages by hand

Use this if you can't import the APEXlang export in [`apex-app/`](../apex-app), or want to add
the upload to an existing app. Page numbers match the export: **4** PAR Upload, **5** Rejected
Rows (modal), **6** Loaded Records. If you use different numbers, change `P5_LOAD_ID` and the
page links to match.

Install the database objects first (see the [README](../README.md#3-install-the-database-objects)).

## Static files

Shared Components → Static Application Files → upload
[`par_upload.js`](../apex-app/shared-components/static-files/par_upload.js) and
[`par_upload.css`](../apex-app/shared-components/static-files/par_upload.css).

Reference them with a version suffix, and bump it every time you upload a new copy, or
browsers keep serving the old one:

```
#APP_FILES#par_upload.js?v=1
#APP_FILES#par_upload.css?v=1
```

## Page 4: PAR Upload

**Page properties**

- JavaScript → File URLs: `#APP_FILES#par_upload.js?v=1`
- CSS → File URLs: `#APP_FILES#par_upload.css?v=1`
- JavaScript → Execute when Page Loads:

  ```js
  parUpload.initDropZone({ dropId: "parDrop", fileInputId: "parFile", fileNameId: "parFileName" });
  ```

**Region `Upload`** (Static Content, header shown). Use a plain file input, not a File
Browse item, so APEX never submits the file to the database:

```html
<div class="par-card">
  <label class="par-drop" id="parDrop" for="parFile">
    <span class="fa fa-cloud-upload par-drop-icon" aria-hidden="true"></span>
    <span class="par-drop-title">Drop a file here or click to browse</span>
    <span class="par-drop-file" id="parFileName">CSV files are loaded into ATP after upload</span>
    <input type="file" id="parFile">
  </label>
  <div class="par-steps">
    <div class="par-step" id="parStepUpload" data-state="pending">
      <span class="par-step-dot"></span>Upload to Object Storage
    </div>
    <div class="par-step" id="parStepLoad" data-state="pending">
      <span class="par-step-dot"></span>Load into ATP
    </div>
  </div>
  <progress class="par-progress" id="parProgress" max="100" value="0"></progress>
  <div class="par-status" id="parStatus"></div>
</div>
```

**Button `UPLOAD`** in the Upload region, position **Next**, Hot, icon `fa-upload`.
Action: Defined by Dynamic Action → **Execute JavaScript Code**:

```js
parUpload.start({
  fileInputId:   "parFile",
  progressId:    "parProgress",
  statusId:      "parStatus",
  stepUploadId:  "parStepUpload",
  stepLoadId:    "parStepLoad",
  refreshRegion: "uploads",
  loadRegion:    "loads"
});
```

Optional **Reset** button: Execute JavaScript Code `parUpload.reset();`

**Ajax Callback processes.** The names must match exactly; the JavaScript calls them by name.

`GET_UPLOAD_URL`

```sql
declare
  l_object_name varchar2(1000);
  l_url         varchar2(2000);
begin
  pkg_oci_par.get_upload_url(
    p_file_name   => apex_application.g_x01,
    p_object_name => l_object_name,
    p_upload_url  => l_url);
  apex_json.open_object;
  apex_json.write('objectName', l_object_name);
  apex_json.write('url', l_url);
  apex_json.close_object;
exception when others then
  apex_json.open_object;
  apex_json.write('error', sqlerrm);
  apex_json.close_object;
end;
```

`START_LOAD`

```sql
declare
  l_load_id number;
begin
  l_load_id := pkg_oci_load.submit_load(apex_application.g_x01);
  apex_json.open_object;
  apex_json.write('loadId', l_load_id);
  apex_json.close_object;
exception when others then
  apex_json.open_object;
  apex_json.write('error', sqlerrm);
  apex_json.close_object;
end;
```

`LOAD_STATUS`

```sql
declare
  l_row oci_load_log%rowtype;
begin
  pkg_oci_load.check_job(to_number(apex_application.g_x01));   -- catches jobs that died
  select * into l_row from oci_load_log where load_id = to_number(apex_application.g_x01);
  apex_json.open_object;
  apex_json.write('status',       l_row.status);
  apex_json.write('rowsLoaded',   l_row.rows_loaded);
  apex_json.write('rowsRejected', l_row.rows_rejected);
  apex_json.write('elapsedSecs',  round(extract(day    from (l_row.completed_ts - l_row.started_ts)) * 86400
                                      + extract(hour   from (l_row.completed_ts - l_row.started_ts)) * 3600
                                      + extract(minute from (l_row.completed_ts - l_row.started_ts)) * 60
                                      + extract(second from (l_row.completed_ts - l_row.started_ts))));
  apex_json.write('error',        l_row.error_message);
  apex_json.close_object;
end;
```

`LOG_UPLOAD_ERROR`

```sql
begin
  pkg_oci_load.log_upload_failure(
    p_file_name   => apex_application.g_x01,
    p_object_name => apex_application.g_x02,
    p_error       => apex_application.g_x03);
end;
```

**Classic Report `Uploaded Files`**, Static ID `uploads`, pagination *Row Ranges X to Y
of Z (with pagination)*:

```sql
select object_name,
       case when bytes >= 1073741824
            then to_char(bytes / 1073741824, 'fm999,990.00') || ' GB'
            else to_char(bytes / 1048576, 'fm999,990.0') || ' MB'
       end as file_size,
       to_char(last_modified, 'DD-MON-YYYY HH24:MI') as uploaded
from table(dbms_cloud.list_objects(
       credential_name => pkg_oci_load.credential_name,
       location_uri    => pkg_oci_load.uploads_uri))
order by last_modified desc
```

**Classic Report `Load History`**, Static ID `loads`:

```sql
select load_id,
       replace(object_name, 'apex_uploads/') as file_name,
       status,
       rows_loaded,
       rows_rejected,
       to_char(submitted_ts, 'DD-MON-YYYY HH24:MI') as submitted,
       round((cast(completed_ts as date) - cast(started_ts as date)) * 86400) as elapsed_secs,
       error_message
from oci_load_log
order by load_id desc
```

Column settings:

| Column | Setting |
|---|---|
| `STATUS` | HTML Expression `<span class="par-badge" data-status="#STATUS#">#STATUS#</span>`, Escape special characters **Off** |
| `ROWS_LOADED`, `ROWS_REJECTED` | Format Mask `999G999G999G990` |
| `ROWS_REJECTED` | Type **Link** → page 5, Set Items `P5_LOAD_ID` = `#LOAD_ID#`, Clear Cache `5`, Link Text `#ROWS_REJECTED#` |

## Page 5: Rejected Rows (modal dialog, width 1000)

- Hidden item `P5_LOAD_ID`.
- Classic Report **Rejected Lines**. Source: *Function Body returning SQL Query*, Use
  Generic Column Names **No**:

  ```sql
  return pkg_oci_load.rejects_query(:P5_LOAD_ID, 'BAD');
  ```

- Classic Report **Reasons**, same settings:

  ```sql
  return pkg_oci_load.rejects_query(:P5_LOAD_ID, 'LOG');
  ```

- In both: `RECORD` HTML Expression `<code>#RECORD#</code>`; No Data Found message
  *No rows were rejected.* In Reasons, head `LINE_NO` **File Row** (the header is row 1).

## Page 6: Loaded Records

**Interactive Report** on table `LANDING_APEX_UPLOAD`, Static ID `records`. Keep
`INVOICE_AMOUNT`, `VENDOR_NUM`, `INVOICE_DATE` and `GL_DATE` displayed; the KPI query reads them.

**Cards region `Tiles`** above it, CSS Classes `invoice-kpis`, header hidden:

```sql
select *
from table(get_invoice_kpis(:APP_PAGE_ID, 'records'))
order by sort_order
```

Attributes: Grid, 5 or 6 columns; Primary Key `KPI_KEY`; Title `TITLE`; Body `DISPLAY`;
Icon Source *Icon Class Column*, Icon Column `ICON_CLASS`.

**Dynamic Action** on the Interactive Report, event *After Refresh* → Refresh `Tiles`,
so the KPIs follow the report's filters and search.

**Page CSS → Inline**: copy the `invoice-kpis` rules from the `css { inline: ... }`
block in [`p00006-loaded-records.apx`](../apex-app/pages/p00006-loaded-records.apx).

**Optional Truncate button** (right of the IR search bar): Confirm → Execute Server-side Code
`begin execute immediate 'truncate table landing_apex_upload'; end;` → Refresh the report and
the Tiles region.
