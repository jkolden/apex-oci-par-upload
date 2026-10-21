"""Generate a test CSV for LANDING_APEX_UPLOAD (see landing_apex_upload.sql).

Examples:
    python make_test_csv.py --rows 1000
    python make_test_csv.py --size-mb 1024 --bad 5

Writes to your Downloads folder by default (not OneDrive, so big files don't sync).
Prints the expected row count and amount total so the load can be reconciled with:
    select count(*), sum(invoice_amount) from landing_apex_upload;
"""
import argparse
import csv
import random
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

HEADER = ["INVOICE_ID", "INVOICE_NUM", "VENDOR_NUM", "VENDOR_NAME", "INVOICE_DATE", "GL_DATE",
          "INVOICE_AMOUNT", "CURRENCY_CODE", "PAYMENT_TERMS", "DESCRIPTION", "CREATED_TS"]

VENDORS = [("V1001", "Contoso Office Supply"), ("V1002", "Northwind Facilities, LLC"),
           ("V1003", "Fabrikam Food Service"), ("V1004", "Tailspin Transportation"),
           ("V1005", "Adventure Works Utilities"), ("V1006", 'Acme "Pro" Janitorial'),
           ("V1007", "Litware IT Services"), ("V1008", "Proseware Printing")]
TERMS = ["NET30", "NET45", "NET60", "IMMEDIATE"]
DESCRIPTIONS = ["Office supplies", "HVAC maintenance, Building C", "Monthly service",
                "Fleet fuel - October", 'Replacement "smart" displays', "Cafeteria produce",
                "Software licenses, annual renewal", "Printing: annual report"]

# Average row length from a sample run; used to turn --size-mb into a row count.
APPROX_ROW_BYTES = 138


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    size = p.add_mutually_exclusive_group(required=True)
    size.add_argument("--rows", type=int, help="number of data rows")
    size.add_argument("--size-mb", type=int, help="approximate file size in MB")
    p.add_argument("--bad", type=int, default=0, help="rows with an invalid amount or date (should be rejected)")
    p.add_argument("--out", type=Path, help="output file (default: Downloads/apinv_test_<rows>.csv)")
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    rows = args.rows or args.size_mb * 1024 * 1024 // APPROX_ROW_BYTES
    out = args.out or Path.home() / "Downloads" / f"apinv_test_{rows}.csv"
    rng = random.Random(args.seed)
    bad_rows = set(rng.sample(range(1, rows + 1), min(args.bad, rows)))

    good_count, total = 0, Decimal("0")
    base_date = date(2026, 1, 1)
    base_ts = datetime(2026, 1, 1, 8, 0, 0)

    with out.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, quoting=csv.QUOTE_MINIMAL)
        w.writerow(HEADER)
        for i in range(1, rows + 1):
            vendor_num, vendor_name = VENDORS[i % len(VENDORS)]
            inv_date = base_date + timedelta(days=rng.randrange(290))
            amount = Decimal(rng.randrange(1000, 5_000_000)) / 100
            row = [i, f"INV-{i:09d}", vendor_num, vendor_name,
                   inv_date.isoformat(), (inv_date + timedelta(days=rng.randrange(5))).isoformat(),
                   f"{amount:.2f}", "USD", TERMS[i % len(TERMS)], DESCRIPTIONS[i % len(DESCRIPTIONS)],
                   (base_ts + timedelta(seconds=i)).strftime("%Y-%m-%d %H:%M:%S")]
            if i in bad_rows:
                if i % 2:
                    row[6] = "N/A"
                else:
                    row[4] = "2026-13-45"
            else:
                good_count += 1
                total += amount
            w.writerow(row)

    print(f"Wrote {out}  ({out.stat().st_size / 1048576:,.1f} MB)")
    print(f"Rows: {rows:,}  (expected loaded: {good_count:,}, rejected: {len(bad_rows):,})")
    print(f"Expected sum(invoice_amount): {total:,.2f}")


if __name__ == "__main__":
    main()
