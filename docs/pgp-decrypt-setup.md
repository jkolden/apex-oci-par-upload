# Automatic PGP decryption with an OCI Function

With this in place, a CSV that the browser PGP-encrypted (`<name>.csv.gz.pgp`) is decrypted
inside OCI and loaded like any other CSV. Without it, encrypted uploads are stored but not loaded.

```
Browser ─► apex_uploads/x.csv.gz.pgp            (ciphertext)
START_LOAD ─► scheduler job (pkg_oci_load.run_load)
   status DECRYPTING ─► OCI Function pgp-decrypt (private key from OCI Vault)
                          streams: get object → gpg --decrypt → gunzip → put object
                          writes apex_staging/x.csv  (plaintext, short-lived)
   status RUNNING    ─► COPY_DATA apex_staging/x.csv → target table
   then              ─► delete apex_staging/x.csv   (+ lifecycle rule as a backstop)
```

The private key lives only in OCI Vault and is readable only by the function. It never
reaches the database, APEX or the browser.

**Time:** about an hour the first time, mostly in the OCI Console. Most steps are one-time
tenancy setup; each one ends with a check so problems surface where they happen.
**Needs:** permission to create dynamic groups and policies (usually tenancy administrators).

Values used below (write yours down as you go):

| Placeholder | Example | Where |
|---|---|---|
| `<namespace>` | `axabc123xyz` | Bucket details |
| `<bucket>` | `my-upload-bucket` | |
| `<compartment-name>` / `<compartment-ocid>` | `apps` / `ocid1.compartment...` | Bucket details → Compartment link |
| `<region>` / `<region-key>` | `us-ashburn-1` / `iad` | [Region list](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm) |
| `<secret-ocid>` | `ocid1.vaultsecret...` | Step 2 |
| `<invoke-url>` | `https://....functions.oci.oraclecloud.com/.../actions/invoke` | Step 7 |

---

## 1. Private key into OCI Vault

1. Identity & Security → **Vault**, in `<compartment-name>`. Reuse an existing vault, or Create
   Vault. Inside it you need an **enabled master encryption key** (Create Key: AES-256 if none).
2. Copy the **private** key that pairs with the public key you put in APEX. With GnuPG
   (Git Bash on Windows: `| clip`; macOS: `| pbcopy`), so it never touches disk:

   ```bash
   gpg --armor --export-secret-keys <key email or id> | clip
   ```

3. Identity & Security → **Secrets Management** → Create secret in `<compartment-name>`:
   name `pgp-private-key`, your vault and key, **Manual secret generation**, template
   **Plain-Text**, paste the whole `-----BEGIN PGP PRIVATE KEY BLOCK-----` … block.
   Leave "Show Base64 conversion" off.
4. Note the secret's **OCID** (`ocid1.vaultsecret...`) → `<secret-ocid>`.

If the key has a passphrase, store it in a second secret and set `PGP_PASSPHRASE_SECRET_OCID`
in step 7.

## 2. Network

The function needs a **private subnet** that can reach Object Storage, Vault and the
container registry: a **service gateway** ("All <region> Services in Oracle Services
Network") and/or a **NAT gateway**.

- **Reuse** an existing VCN if it has those (the VCN Wizard's "VCN with Internet
  Connectivity" creates exactly this: `public subnet-X`, `private subnet-X`, NAT and
  service gateways). Check its Gateways tab.
- Otherwise: Networking → Virtual Cloud Networks → **Start VCN Wizard** → *Create VCN with
  Internet Connectivity*.

Note which compartment the VCN is in; step 4's first policy line depends on it.

## 3. Dynamic group

Identity & Security → Domains → **Default** → Dynamic groups → Create:

- Name: `par-pgp-decrypt-fn`
- Rule: `ALL {resource.type = 'fnfunc', resource.compartment.id = '<compartment-ocid>'}`

## 4. Policy (root compartment)

Identity & Security → Policies → compartment **root** → Create Policy `par-pgp-decrypt`,
manual editor:

```
Allow service faas to use virtual-network-family in tenancy
Allow service faas to read repos in tenancy
Allow dynamic-group par-pgp-decrypt-fn to read secret-bundles in compartment <compartment-name> where target.secret.name = 'pgp-private-key'
Allow dynamic-group par-pgp-decrypt-fn to manage objects in compartment <compartment-name> where target.bucket.name = '<bucket>'
Allow service objectstorage-<region> to manage object-family in compartment <compartment-name>
```

- Line 1 can be narrowed to `in compartment <vcn-compartment>`.
- Line 5 lets the bucket's lifecycle rule (step 8) delete objects.
- If `<compartment-name>` is nested, use its path, e.g. `Parent:Child`.
- Members of Administrators can already deploy and invoke functions; other users need
  `use fn-invocation` and `manage functions-family` grants.

## 5. Functions application

Developer Services → Functions → Applications → (compartment `<compartment-name>`) → Create:
name `par-upload`, your VCN and its **private** subnet, and a **shape that matches the
machine you'll build on** (step 6):

| Build machine (`uname -m`) | Shape |
|---|---|
| `aarch64` (Cloud Shell often defaults to ARM) | `GENERIC_ARM` |
| `x86_64` | `GENERIC_X86` |

The shape can't be changed later. An empty app can simply be deleted and recreated.

## 6. Build and deploy (Cloud Shell)

1. Profile → Tokens and keys → **Auth tokens** → Generate (for the container registry; max
   two per user). Copy it straight away, it's shown once.
2. Open **Cloud Shell** (`>_` in the Console header). Run `uname -m` and confirm it matches
   the app shape. Upload the four files in `oci-function/pgp-decrypt/` as a zip with the
   **upload button at the top right of the Cloud Shell panel** (or the ⚙ menu), then:

   ```bash
   unzip -o pgp-decrypt.zip -d pgp-decrypt && cd pgp-decrypt

   fn use context <region>
   fn update context oracle.compartment-id <compartment-ocid>
   fn update context registry <region-key>.ocir.io/<namespace>/par-upload

   # Username: <namespace>/<username> for the Default identity domain,
   #           <namespace>/<domain>/<username> otherwise. Password: the auth token.
   docker login <region-key>.ocir.io -u '<namespace>/<username>'

   fn -v deploy --app par-upload          # 3–6 minutes the first time
   fn config function par-upload pgp-decrypt PGP_KEY_SECRET_OCID <secret-ocid>
   fn inspect function par-upload pgp-decrypt | grep -o 'https://[^"]*'   # → <invoke-url>
   ```

3. **Check** with an encrypted object already in the bucket:

   ```bash
   echo '{"namespace":"<namespace>","bucket":"<bucket>","object":"apex_uploads/<file>.csv.gz.pgp","target":"apex_staging/check.csv"}' \
     | fn invoke par-upload pgp-decrypt
   oci os object get -bn <bucket> --name apex_staging/check.csv --file - | head -3
   oci os object delete -bn <bucket> --object-name apex_staging/check.csv --force
   ```

   Expect `{"target": "apex_staging/check.csv", "bytes": ..., "seconds": ...}` and readable
   CSV lines. Errors name the cause (secret access, bucket access, wrong key). New policies
   can take a minute to apply.

Function configuration (all via `fn config function par-upload pgp-decrypt <KEY> <value>`):

| Key | Default | Purpose |
|---|---|---|
| `PGP_KEY_SECRET_OCID` | required | Secret holding the armored private key |
| `PGP_PASSPHRASE_SECRET_OCID` | none | Secret holding the key's passphrase, if any |
| `SOURCE_PREFIX` | `apex_uploads/` | Only objects under this prefix can be read |
| `TARGET_PREFIX` | `apex_staging/` | Only objects under this prefix can be written |

## 7. Lifecycle rule (backstop)

Bucket → Management → Lifecycle policy rules → Create: name `delete-staging`, target
**Latest Version of Objects**, action **Delete**, **1 day**, object name filter
**Include by prefix** `apex_staging/`. **Set the prefix filter**: without it the rule
applies to the whole bucket.

If the bucket has **object versioning** enabled, deleted staging files remain as previous
versions. Add a second rule with target **Previous Versions of Objects** and the same
prefix, or stage into a separate unversioned bucket.

## 8. Database

1. A `DBMS_CLOUD` credential that signs with an **OCI API key** (auth-token credentials
   can't call Functions). Use an API key of a user allowed to invoke the function. The
   private key goes in without the BEGIN/END lines, on one line:

   ```bash
   grep -v -- '-----' <private-key>.pem | tr -d '\r\n' | clip
   ```

   ```sql
   begin
     dbms_cloud.create_credential(
       credential_name => 'OCI_API_KEY_CRED',
       user_ocid       => '<user ocid>',
       tenancy_ocid    => '<tenancy ocid>',
       private_key     => '<paste>',
       fingerprint     => '<fingerprint>');
   end;
   ```

   On Autonomous Database you can use the database's **resource principal** instead
   (`dbms_cloud_admin.enable_resource_principal`, plus a dynamic group and
   `use fn-invocation` policy for it) and set `gc_fn_credential` to `OCI$RESOURCE_PRINCIPAL`.
2. Set `gc_fn_invoke_url` in `db/pkg_oci_load.sql` to `<invoke-url>`, then compile
   `pkg_oci_load.sql` and `pkg_oci_load.plb`.
3. **Check** (SQL Commands):

   ```sql
   declare
     l varchar2(1000);
   begin
     l := pkg_oci_load.decrypt_to_staging('apex_uploads/<file>.csv.gz.pgp');
     dbms_output.put_line(l);      -- apex_staging/<file>.csv
   end;
   ```

   Then delete that staging object. A `401` means the credential's key, fingerprint or
   OCIDs are wrong; a `404` usually means a typo in the invoke URL.

## 9. APEX

Add `loadEncrypted: true` to the Upload button's `parUpload.start({...})` options. Encrypted
CSVs now show **Decrypting in OCI…**, then **Loading into ATP…**, then the row counts.

## Limits and notes

- The function streams, so memory stays flat at any file size. The database waits up to
  **300 s** for it (`utl_http.set_transfer_timeout` in `decrypt_to_staging`, and the
  function's `timeout` in `func.yaml`). Very large files may need OCI Functions' detached
  invocation with the job polling for completion.
- The plaintext staging copy exists only for the duration of the load, and anyone who can read the
  bucket can read it during that window. Use a separate staging bucket with tighter access
  if that matters.
- Cost at proof-of-concept volume is negligible: no hourly charges, Functions has a monthly
  free allowance, and the image and staging objects are a few hundred MB of storage.

## Cleanup

| Created | Remove |
|---|---|
| Secret `pgp-private-key` | Secrets Management → Schedule deletion (1–30 day wait) |
| Dynamic group `par-pgp-decrypt-fn` | Domains → Default → Dynamic groups → Delete |
| Policy `par-pgp-decrypt` | Policies → Delete |
| Function `pgp-decrypt`, app `par-upload` | Delete the function, then the app |
| Repository `par-upload/pgp-decrypt` | Container Registry → Delete repository |
| Auth token | Profile → Tokens and keys → Delete |
| Lifecycle rule `delete-staging` | Bucket → Lifecycle policy rules → Delete |
| `OCI_API_KEY_CRED` | `exec dbms_cloud.drop_credential('OCI_API_KEY_CRED')` |
