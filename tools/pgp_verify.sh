#!/usr/bin/env bash
# Prove a PGP upload round trip: the object in the bucket is unreadable ciphertext, and
# decrypting it with the private key gives back the original file byte for byte.
#
# Usage:
#   tools/pgp_verify.sh <encrypted file or read-PAR URL> <original file>
#
# Uses the POC test keyring (~/.gnupg-par-poc) unless GNUPGHOME is set.
set -euo pipefail

src="${1:?encrypted file or URL}"
orig="${2:?original file}"
export GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg-par-poc}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ "$src" == https://* ]]; then
    echo "Downloading from bucket..."
    curl -fsS -o "$work/upload.gz.pgp" "$src"
    src="$work/upload.gz.pgp"
fi

echo
echo "== 1. What's in the bucket (first 64 bytes):"
head -c 64 "$src" | od -An -c | head -4
echo "   (binary ciphertext; no CSV text visible)"

echo
echo "== 2. Decrypt with the private key, then gunzip:"
gpg --batch --decrypt "$src" 2>"$work/gpg.log" | gzip -dc > "$work/decrypted"
grep -E "encrypted with|created" "$work/gpg.log" | sed 's/^/   /' || true
head -3 "$work/decrypted" | sed 's/^/   /'

echo
echo "== 3. Compare with the original:"
a="$(sha256sum < "$orig" | cut -d' ' -f1)"
b="$(sha256sum < "$work/decrypted" | cut -d' ' -f1)"
printf '   original   %s  (%s bytes)\n' "$a" "$(wc -c < "$orig")"
printf '   decrypted  %s  (%s bytes)\n' "$b" "$(wc -c < "$work/decrypted")"
printf '   in bucket  %s bytes (%s%% of original)\n' "$(wc -c < "$src")" \
       "$(( 100 * $(wc -c < "$src") / $(wc -c < "$orig") ))"
if [[ "$a" == "$b" ]]; then echo "   MATCH: identical to the original"; else echo "   MISMATCH"; exit 1; fi
