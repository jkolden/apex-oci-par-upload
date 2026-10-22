"""OCI Function: decrypt a PGP-encrypted upload into a short-lived staging object.

Invoked by the database (pkg_oci_load.run_load) with:
    {"namespace": "...", "bucket": "...", "object": "apex_uploads/x.csv.gz.pgp",
     "target": "apex_staging/x.csv"}

Streams: Object Storage -> gpg --decrypt -> gunzip -> Object Storage multipart upload,
so memory stays flat regardless of file size. The private key comes from an OCI Vault
secret (config PGP_KEY_SECRET_OCID) and is imported into a throwaway keyring per call.

Function configuration:
    PGP_KEY_SECRET_OCID         required  secret holding the ASCII-armored private key
    PGP_PASSPHRASE_SECRET_OCID  optional  secret holding the key's passphrase
    SOURCE_PREFIX               default apex_uploads/   only objects under this are read
    TARGET_PREFIX               default apex_staging/   only objects under this are written
"""
import base64
import gzip
import io
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time

PART_SIZE = 32 * 1024 * 1024
PARALLEL_PARTS = 3


class DecryptError(Exception):
    pass


def decrypt_stream(src, sink, private_key, passphrase=None):
    """Decrypt PGP data read from file-like `src`, gunzip it, and pass a readable
    plaintext stream to `sink(stream)`. Raises DecryptError if gpg fails."""
    home = tempfile.mkdtemp(prefix="gnupg-")
    try:
        os.chmod(home, 0o700)
        env = dict(os.environ, GNUPGHOME=home)
        imp = subprocess.run(["gpg", "--batch", "--import"], input=private_key,
                             env=env, capture_output=True)
        if imp.returncode != 0:
            raise DecryptError("key import failed: " + imp.stderr.decode(errors="replace"))

        cmd = ["gpg", "--batch", "--no-tty", "--decrypt"]
        pass_r = None
        if passphrase:
            pass_r, pass_w = os.pipe()
            os.write(pass_w, passphrase)
            os.close(pass_w)
            cmd[3:3] = ["--pinentry-mode", "loopback", "--passphrase-fd", str(pass_r)]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env,
                                pass_fds=(pass_r,) if pass_r else ())
        if pass_r:
            os.close(pass_r)

        def feed():
            try:
                shutil.copyfileobj(src, proc.stdin, 1024 * 1024)
            except BrokenPipeError:
                pass   # gpg stopped reading; its exit code reports why
            finally:
                proc.stdin.close()

        stderr = []
        threading.Thread(target=feed, daemon=True).start()
        err_t = threading.Thread(target=lambda: stderr.append(proc.stderr.read()), daemon=True)
        err_t.start()

        # The browser writes one gzip member per 1 MB block; GzipFile reads them as one file.
        try:
            sink(gzip.GzipFile(fileobj=proc.stdout, mode="rb"))
        finally:
            rc = proc.wait()
            err_t.join()
        if rc != 0:
            raise DecryptError("gpg failed: " + b"".join(stderr).decode(errors="replace"))
    finally:
        shutil.rmtree(home, ignore_errors=True)


def _secret_bytes(secrets_client, ocid):
    bundle = secrets_client.get_secret_bundle(ocid).data
    return base64.b64decode(bundle.secret_bundle_content.content)


def handler(ctx, data: io.BytesIO = None):
    import oci
    from fdk import response

    started = time.time()
    try:
        req = json.loads(data.getvalue())
        namespace, bucket = req["namespace"], req["bucket"]
        source, target = req["object"], req["target"]
        cfg = dict(ctx.Config())
        src_prefix = cfg.get("SOURCE_PREFIX", "apex_uploads/")
        dst_prefix = cfg.get("TARGET_PREFIX", "apex_staging/")
        if not source.startswith(src_prefix) or not target.startswith(dst_prefix):
            raise DecryptError(f"object must be under {src_prefix} and target under {dst_prefix}")

        signer = oci.auth.signers.get_resource_principals_signer()
        secrets = oci.secrets.SecretsClient(config={}, signer=signer)
        storage = oci.object_storage.ObjectStorageClient(config={}, signer=signer)
        key = _secret_bytes(secrets, cfg["PGP_KEY_SECRET_OCID"])
        phrase = (_secret_bytes(secrets, cfg["PGP_PASSPHRASE_SECRET_OCID"])
                  if cfg.get("PGP_PASSPHRASE_SECRET_OCID") else None)

        src = storage.get_object(namespace, bucket, source).data.raw
        uploader = oci.object_storage.UploadManager(storage, allow_parallel_uploads=True,
                                                    parallel_process_count=PARALLEL_PARTS)

        def sink(stream):
            uploader.upload_stream(namespace, bucket, target, stream, part_size=PART_SIZE,
                                   content_type="text/csv")

        try:
            decrypt_stream(src, sink, key, phrase)
        except Exception:
            try:   # never leave a partial plaintext object behind
                storage.delete_object(namespace, bucket, target)
            except Exception:
                pass
            raise

        size = storage.head_object(namespace, bucket, target).headers.get("content-length")
        body = {"target": target, "bytes": int(size or 0), "seconds": round(time.time() - started, 1)}
        return response.Response(ctx, response_data=json.dumps(body),
                                 headers={"Content-Type": "application/json"})
    except Exception as e:
        return response.Response(ctx, status_code=400,
                                 response_data=json.dumps({"error": f"{type(e).__name__}: {e}"}),
                                 headers={"Content-Type": "application/json"})
