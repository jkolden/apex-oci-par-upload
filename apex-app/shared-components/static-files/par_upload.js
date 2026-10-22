/*
 * par_upload.js
 * Browser-direct upload to OCI Object Storage using a pre-authenticated request (PAR).
 * The APEX Ajax callback GET_UPLOAD_URL returns a single-object ObjectWrite PAR from
 * pkg_oci_par.get_upload_url; the file bytes never pass through ATP.
 *
 * Files above MULTIPART_THRESHOLD use the OCI multipart-via-PAR protocol:
 *   PUT  <par url>            header opc-multipart: true  -> { accessUri }
 *   PUT  <accessUri><partNo>  part bytes (1-based, max 10,000 parts)
 *   POST <accessUri>          commit
 *   DELETE <accessUri>        abort
 *
 * CSV uploads are then loaded into ATP by pkg_oci_load (START_LOAD / LOAD_STATUS callbacks).
 *
 * Optional PGP encryption (opts.encryptToggleId checked): the file is gzipped in 1 MB blocks and
 * encrypted in the browser with OpenPGP.js (window.openpgp) using the public key at
 * opts.publicKeyUrl, then uploaded as <name>.gz.pgp. Decrypt with: gpg -d file.gz.pgp | gzip -dc
 */
var parUpload = (function () {
    "use strict";

    var PART_SIZE           = 64 * 1024 * 1024;   // 64 MiB (OCI minimum is 10 MiB, except the last part)
    var MULTIPART_THRESHOLD = 128 * 1024 * 1024;  // single PUT below this size
    var CONCURRENCY         = 4;                  // parts in flight at once
    var MAX_RETRIES         = 3;                  // per part
    var POLL_MS             = 3000;               // ATP load status poll interval
    var LOAD_TIMEOUT_MS     = 60 * 60 * 1000;     // stop polling after an hour

    function send(method, url, body, headers, onProgress) {
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            xhr.open(method, url);
            Object.keys(headers || {}).forEach(function (h) {
                xhr.setRequestHeader(h, headers[h]);
            });
            if (onProgress) {
                xhr.upload.onprogress = function (e) {
                    if (e.lengthComputable) { onProgress(e.loaded); }
                };
            }
            xhr.onload = function () {
                if (xhr.status >= 200 && xhr.status < 300) {
                    resolve(xhr);
                } else {
                    reject(new Error(method + " failed: HTTP " + xhr.status + " " + xhr.responseText));
                }
            };
            xhr.onerror = function () {
                reject(new Error(method + " failed: network error (check CORS, PAR expiry, connectivity)"));
            };
            xhr.send(body === undefined ? null : body);
        });
    }

    function sleep(ms) {
        return new Promise(function (resolve) { setTimeout(resolve, ms); });
    }

    async function singleUpload(parUrl, file, onBytes) {
        await send("PUT", parUrl, file, {}, onBytes);
    }

    async function multipartUpload(parUrl, file, onBytes) {
        var origin    = new URL(parUrl).origin;
        var start     = await send("PUT", parUrl, null, { "opc-multipart": "true" });
        var uploadUri = origin + JSON.parse(start.responseText).accessUri;
        var partCount = Math.ceil(file.size / PART_SIZE);
        var loaded    = new Array(partCount).fill(0);
        var next      = 0;

        function report() {
            onBytes(loaded.reduce(function (a, b) { return a + b; }, 0));
        }

        async function uploadPart(i) {
            var blob = file.slice(i * PART_SIZE, Math.min(file.size, (i + 1) * PART_SIZE));
            for (var attempt = 1; ; attempt++) {
                try {
                    await send("PUT", uploadUri + (i + 1), blob, {}, function (b) { loaded[i] = b; report(); });
                    loaded[i] = blob.size;
                    report();
                    return;
                } catch (e) {
                    loaded[i] = 0;
                    report();
                    if (attempt >= MAX_RETRIES) { throw e; }
                    await sleep(1000 * attempt * attempt);
                }
            }
        }

        async function worker() {
            while (next < partCount) {
                await uploadPart(next++);
            }
        }

        try {
            var workers = [];
            for (var w = 0; w < Math.min(CONCURRENCY, partCount); w++) { workers.push(worker()); }
            await Promise.all(workers);
            await send("POST", uploadUri);
        } catch (e) {
            send("DELETE", uploadUri).catch(function () {});
            throw e;
        }
    }

    // ---- PGP encryption ---------------------------------------------------------------

    var ENC_PART_SIZE  = 16 * 1024 * 1024;   // smaller parts keep buffered ciphertext ~100 MB
    var ENC_BLOCK_SIZE = 1024 * 1024;        // raw bytes gzipped per block
    var publicKeys     = {};                 // url -> parsed key

    async function readPublicKey(url) {
        if (!publicKeys[url]) {
            if (!window.openpgp) { throw new Error("OpenPGP.js is not loaded on this page."); }
            var res = await fetch(url, { credentials: "same-origin" });
            if (!res.ok) { throw new Error("Could not load the PGP public key (HTTP " + res.status + ")."); }
            publicKeys[url] = await openpgp.readKey({ armoredKey: await res.text() });
        }
        return publicKeys[url];
    }

    async function gzipBlock(bytes) {
        var gz = new Blob([bytes]).stream().pipeThrough(new CompressionStream("gzip"));
        return new Uint8Array(await new Response(gz).arrayBuffer());
    }

    /*
     * Gzip the file in 1 MB blocks (a multi-member gzip, which gzip and zlib tools read as one
     * file), PGP-encrypt it, and upload the ciphertext as it is produced. OpenPGP.js's own
     * compression is off because it reads far ahead of a slow upload; this pull-based source only
     * reads the next block when the encryptor asks, and the encryptor only asks when the upload
     * has room, so memory stays around 100 MB at any file size.
     * onProgress(fraction): ciphertext uploaded / estimated final ciphertext size.
     * Resolves with the encrypted size in bytes.
     */
    async function encryptAndUpload(parUrl, file, publicKey, onProgress) {
        var inRead = 0;
        var source = new ReadableStream({
            async pull(ctl) {
                if (inRead >= file.size) { ctl.close(); return; }
                var raw = new Uint8Array(await file.slice(inRead, inRead + ENC_BLOCK_SIZE).arrayBuffer());
                inRead += raw.length;
                ctl.enqueue(await gzipBlock(raw));
            }
        }, { highWaterMark: 0 });

        var message   = await openpgp.createMessage({ binary: source, format: "binary" });
        var encrypted = await openpgp.encrypt({
            message: message, encryptionKeys: publicKey, format: "binary",
            config: { preferredCompressionAlgorithm: openpgp.enums.compression.uncompressed }
        });
        var reader = encrypted.getReader();

        var produced = 0, done = false, buf = [], bufLen = 0;
        var uploaded = [];   // bytes sent, per part

        function report() {
            var sent     = uploaded.reduce(function (a, b) { return a + b; }, 0);
            var estTotal = done ? produced : produced * file.size / Math.max(inRead, 1);
            onProgress(estTotal ? Math.min(1, sent / estTotal) : 0);
        }

        // Read ciphertext until a full part is buffered or the stream ends.
        async function nextPart() {
            while (!done && bufLen < ENC_PART_SIZE) {
                var r = await reader.read();
                if (r.done) { done = true; break; }
                buf.push(r.value); bufLen += r.value.length; produced += r.value.length;
            }
            var part = new Blob(buf);
            buf = []; bufLen = 0;
            return part;
        }

        var part = await nextPart();
        if (done) {   // small enough for one request
            await send("PUT", parUrl, part, {}, function (b) { uploaded[0] = b; report(); });
            uploaded[0] = part.size; report();
            return produced;
        }

        var origin    = new URL(parUrl).origin;
        var start     = await send("PUT", parUrl, null, { "opc-multipart": "true" });
        var uploadUri = origin + JSON.parse(start.responseText).accessUri;
        var inFlight  = new Set();
        var failure   = null;

        async function putPart(n, blob) {
            for (var attempt = 1; ; attempt++) {
                try {
                    await send("PUT", uploadUri + n, blob, {}, function (b) { uploaded[n - 1] = b; report(); });
                    uploaded[n - 1] = blob.size; report();
                    return;
                } catch (e) {
                    uploaded[n - 1] = 0; report();
                    if (attempt >= MAX_RETRIES) { throw e; }
                    await sleep(1000 * attempt * attempt);
                }
            }
        }

        function track(promise) {
            var t = promise
                .catch(function (e) { failure = failure || e; })
                .then(function () { inFlight.delete(t); });
            inFlight.add(t);
        }

        try {
            var partNo = 0;
            while (part.size > 0) {
                track(putPart(++partNo, part));
                while (inFlight.size >= CONCURRENCY && !failure) { await Promise.race(inFlight); }
                if (failure) { throw failure; }
                part = done ? new Blob([]) : await nextPart();
            }
            await Promise.all(inFlight);
            if (failure) { throw failure; }
            await send("POST", uploadUri);
            return produced;
        } catch (e) {
            reader.cancel().catch(function () {});
            send("DELETE", uploadUri).catch(function () {});
            throw e;
        }
    }

    /*
     * Submit the ATP load (START_LOAD) and poll LOAD_STATUS until it finishes.
     * Resolves with the final status row; rejects if the load errors.
     */
    async function loadIntoAtp(objectName, status) {
        var started = Date.now();
        var sub = await apex.server.process("START_LOAD", { x01: objectName });
        if (sub.error) { throw new Error(sub.error); }

        for (;;) {
            await sleep(POLL_MS);
            if (Date.now() - started > LOAD_TIMEOUT_MS) {
                throw new Error("Load " + sub.loadId + " is still running after " +
                                formatDuration(LOAD_TIMEOUT_MS / 1000) + ". Check Load History for the result.");
            }
            var s = await apex.server.process("LOAD_STATUS", { x01: sub.loadId });
            var secs = ((Date.now() - started) / 1000).toFixed(0);
            if (s.status === "SUCCESS") { return s; }
            if (s.status === "ERROR")   { throw new Error("Load failed: " + s.error); }
            status.textContent = s.status === "DECRYPTING"
                ? "Decrypting in OCI (" + secs + "s)..."
                : "Loading into ATP (" + s.status.toLowerCase() + ", " + secs + "s)...";
        }
    }

    function formatDuration(secs) {
        secs = Math.round(secs);
        return secs >= 60 ? Math.floor(secs / 60) + "m " + (secs % 60) + "s" : secs + "s";
    }

    function formatSize(bytes) {
        return bytes >= 1073741824 ? (bytes / 1073741824).toFixed(2) + " GB"
                                   : (bytes / 1048576).toFixed(1) + " MB";
    }

    // state: pending | active | done | error | skipped (styled by par_upload.css)
    function setStep(id, state) {
        var el = id && document.getElementById(id);
        if (el) { el.setAttribute("data-state", state); }
    }

    var busy     = false;   // an upload or load is in progress
    var lastOpts = null;    // opts from the most recent start(), used to reset its display
    var dropZone = null;    // elements from initDropZone

    // Put steps, progress bar and status text back to their initial state.
    function resetStatus(opts) {
        if (!opts) { return; }
        var progress = document.getElementById(opts.progressId);
        var status   = document.getElementById(opts.statusId);
        if (progress) { progress.value = 0; }
        if (status)   { status.textContent = ""; }
        setStep(opts.stepUploadId, "pending");
        setStep(opts.stepLoadId, "pending");
    }

    // Clear the selected file and restore the drop zone's prompt text.
    function clearFile() {
        if (!dropZone) { return; }
        dropZone.input.value = "";
        dropZone.drop.classList.remove("has-file");
        dropZone.name.textContent = dropZone.defaultText;
    }

    /*
     * Make the drop zone accept dragged files and show the chosen file's name and size.
     * Choosing a new file clears the previous run's steps, progress and status.
     * opts.dropId, opts.fileInputId, opts.fileNameId, optional opts.encryptToggleId
     */
    function initDropZone(opts) {
        var drop    = document.getElementById(opts.dropId);
        var input   = document.getElementById(opts.fileInputId);
        var name    = document.getElementById(opts.fileNameId);
        var encrypt = opts.encryptToggleId && document.getElementById(opts.encryptToggleId);
        dropZone    = { drop: drop, input: input, name: name, defaultText: name.textContent };

        function describe() {
            var f = input.files[0];
            if (!f) { return; }
            name.textContent = f.name + "  ·  " + formatSize(f.size) +
                               (encrypt && encrypt.checked ? "  ·  will be PGP-encrypted"
                                : /\.csv$/i.test(f.name) ? "  ·  will load into ATP" : "");
        }

        function show() {
            if (!input.files[0]) { return; }
            if (!busy) { resetStatus(lastOpts); }
            describe();
            drop.classList.add("has-file");
        }

        if (encrypt) { encrypt.addEventListener("change", describe); }
        input.addEventListener("change", show);
        ["dragenter", "dragover"].forEach(function (ev) {
            drop.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.add("is-over"); });
        });
        ["dragleave", "drop"].forEach(function (ev) {
            drop.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.remove("is-over"); });
        });
        drop.addEventListener("drop", function (e) {
            if (e.dataTransfer.files.length) {
                input.files = e.dataTransfer.files;
                show();
            }
        });
    }

    /*
     * opts.fileInputId   id of the <input type="file">
     * opts.progressId    id of a <progress max="100"> element
     * opts.statusId      id of an element for status text
     * opts.stepUploadId  optional id of the "upload" step element
     * opts.stepLoadId    optional id of the "load" step element
     * opts.refreshRegion optional static id of a region to refresh when done
     * opts.loadRegion    optional static id of the load history region to refresh
     * opts.encryptToggleId optional id of a checkbox; when checked the file is PGP-encrypted
     * opts.publicKeyUrl  URL of the armored PGP public key (required when encrypting)
     * opts.loadEncrypted true to load encrypted CSVs too (needs the pgp-decrypt OCI Function)
     */
    async function start(opts) {
        var input    = document.getElementById(opts.fileInputId);
        var progress = document.getElementById(opts.progressId);
        var status   = document.getElementById(opts.statusId);
        var file     = input && input.files[0];

        if (busy) { return; }
        if (!file) {
            apex.message.alert("Choose a file first.");
            return;
        }
        busy     = true;
        lastOpts = opts;

        var toggle     = opts.encryptToggleId && document.getElementById(opts.encryptToggleId);
        var encrypt    = !!(toggle && toggle.checked);
        // Encrypted CSVs are only loaded when the server can decrypt them (pgp-decrypt function).
        var isCsv      = /\.csv$/i.test(file.name) && (!encrypt || !!opts.loadEncrypted);
        var phase      = "upload";
        var started    = Date.now();
        var objectName = null;
        var sentBytes  = 0;
        function onBytes(bytes) {
            sentBytes = bytes;
            progress.value = file.size ? Math.floor(bytes * 100 / file.size) : 100;
            status.textContent = (encrypt ? "Encrypting and uploading: " : "") +
                                 formatSize(bytes) + " of " + formatSize(file.size);
        }

        apex.message.clearErrors();
        progress.value = 0;
        status.textContent = "Requesting upload URL...";
        setStep(opts.stepUploadId, "active");
        setStep(opts.stepLoadId, isCsv ? "pending" : "skipped");

        try {
            var key = encrypt ? await readPublicKey(opts.publicKeyUrl) : null;
            var par = await apex.server.process("GET_UPLOAD_URL", { x01: encrypt ? file.name + ".gz.pgp" : file.name });
            if (par.error) { throw new Error(par.error); }
            objectName = par.objectName;

            var storedSize = file.size;
            if (encrypt) {
                storedSize = await encryptAndUpload(par.url, file, key, function (f) { onBytes(f * file.size); });
            } else if (file.size > MULTIPART_THRESHOLD) {
                await multipartUpload(par.url, file, onBytes);
            } else {
                await singleUpload(par.url, file, onBytes);
            }

            var secs = (Date.now() - started) / 1000;
            progress.value = 100;
            status.textContent = encrypt
                ? "PGP-encrypted " + formatSize(file.size) + " to " + formatSize(storedSize) +
                  " (" + Math.round(100 * storedSize / Math.max(file.size, 1)) + "%) and uploaded in " + formatDuration(secs)
                : "Upload to Object Storage: " + formatSize(file.size) + " in " +
                  formatDuration(secs) + " (" + (file.size / 1048576 / secs).toFixed(1) + " MB/s)";
            setStep(opts.stepUploadId, "done");
            if (opts.refreshRegion) { apex.region(opts.refreshRegion).refresh(); }

            // Only CSVs are loaded into ATP; other files just stay in the bucket.
            if (isCsv) {
                var uploadMsg = status.textContent;
                phase = "load";
                setStep(opts.stepLoadId, "active");
                progress.removeAttribute("value");   // indeterminate bar while ATP loads
                var load = await loadIntoAtp(par.objectName, status);
                progress.value = 100;
                setStep(opts.stepLoadId, "done");
                status.textContent = uploadMsg + "  ·  Load into ATP: " +
                                     Number(load.rowsLoaded).toLocaleString() + " rows in " +
                                     formatDuration(load.elapsedSecs) +
                                     (load.rowsRejected ? " (" + load.rowsRejected + " rejected)" : "") +
                                     "  ·  Total: " + formatDuration((Date.now() - started) / 1000);
                apex.message.showPageSuccess("Loaded " + Number(load.rowsLoaded).toLocaleString() +
                                             " rows from " + par.objectName);
                if (opts.loadRegion) { apex.region(opts.loadRegion).refresh(); }
            } else {
                apex.message.showPageSuccess((encrypt ? "Uploaded encrypted " : "Uploaded ") + par.objectName);
            }
            // Ready for the next file; results stay visible until a new file is chosen.
            clearFile();
        } catch (e) {
            // Keep the file selected so the user can retry.
            progress.value = 0;
            setStep(phase === "load" ? opts.stepLoadId : opts.stepUploadId, "error");
            status.textContent = phase === "load" ? "Load failed" : "Upload failed";
            apex.message.showErrors([{ type: "error", location: "page", message: e.message, unsafe: false }]);

            // Load failures are already in oci_load_log; record upload failures too.
            if (phase === "upload") {
                apex.server.process("LOG_UPLOAD_ERROR", {
                    x01: file.name,
                    x02: objectName || "",
                    x03: "Failed after " + formatSize(sentBytes) + " of " + formatSize(file.size) +
                         " (" + formatDuration((Date.now() - started) / 1000) + "): " + e.message
                }).then(function () {
                    if (opts.loadRegion) { apex.region(opts.loadRegion).refresh(); }
                }).catch(function () {});
            }
        } finally {
            busy = false;
        }
    }

    // Clear the file and the last run's display, e.g. from a Reset button.
    function reset() {
        if (busy) { return; }
        clearFile();
        resetStatus(lastOpts);
        apex.message.clearErrors();
    }

    return { start: start, initDropZone: initDropZone, reset: reset };
})();
