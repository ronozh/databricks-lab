"""
Run SQL against the lab's Databricks SQL warehouse from the shell.

    python3 infra/dbsql.py "SELECT 1"
    python3 infra/dbsql.py --file setup.sql

Uses the Databricks CLI for auth, so there is no token in this repo and no SDK to
install. The warehouse is discovered rather than hard-coded -- see D4.
"""
import argparse, json, subprocess, sys, time


def cli(*args, profile="free"):
    p = subprocess.run(["databricks", *args, "--profile", profile],
                       capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def warehouse_id(profile):
    rc, out, err = cli("warehouses", "list", "-o", "json", profile=profile)
    if rc or not out:
        sys.exit(f"cannot list warehouses: {err or out}")
    whs = json.loads(out)
    if not whs:
        sys.exit("no SQL warehouse in this workspace")
    return (([w for w in whs if w.get("state") == "RUNNING"] or whs)[0])["id"]


def run(stmt, profile="free", wh=None, catalog=None, timeout=900):
    """Returns (ok, result_dict) or (False, error_string)."""
    wh = wh or warehouse_id(profile)
    body = {"warehouse_id": wh, "statement": stmt, "wait_timeout": "30s"}
    if catalog:
        body["catalog"] = catalog
    rc, out, err = cli("api", "post", "/api/2.0/sql/statements",
                       "--json", json.dumps(body), profile=profile)
    if rc:
        return False, err or out
    r = json.loads(out)
    sid, waited = r.get("statement_id"), 0
    # The API returns once wait_timeout elapses; long statements need polling.
    while r.get("status", {}).get("state") in ("PENDING", "RUNNING") and waited < timeout:
        time.sleep(2)
        waited += 2
        rc, out, err = cli("api", "get", f"/api/2.0/sql/statements/{sid}", profile=profile)
        if rc:
            return False, err
        r = json.loads(out)
    st = r.get("status", {})
    if st.get("state") != "SUCCEEDED":
        return False, json.dumps(st.get("error", st))
    return True, r.get("result", {})


def split_statements(text):
    """Naive ';' splitter that drops line comments and empty statements."""
    out, buf = [], []
    for line in text.splitlines():
        if line.strip().startswith("--"):
            continue
        buf.append(line)
        if line.rstrip().endswith(";"):
            s = "\n".join(buf).strip().rstrip(";").strip()
            if s:
                out.append(s)
            buf = []
    tail = "\n".join(buf).strip()
    if tail:
        out.append(tail)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("statement", nargs="?")
    ap.add_argument("--file")
    ap.add_argument("--profile", default="free")
    ap.add_argument("--catalog")
    a = ap.parse_args()

    if a.file:
        stmts = split_statements(open(a.file).read())
    elif a.statement:
        stmts = [a.statement]
    else:
        sys.exit("give a statement or --file")

    wh = warehouse_id(a.profile)
    failed = 0
    for s in stmts:
        label = " ".join(s.split())[:88]
        ok, res = run(s, profile=a.profile, wh=wh, catalog=a.catalog)
        if ok:
            rows = res.get("data_array") or []
            print(f"ok   {label}")
            for r in rows[:25]:
                print("       ", r)
            if len(rows) > 25:
                print(f"        … {len(rows) - 25} more")
        else:
            failed += 1
            print(f"FAIL {label}\n       {str(res)[:400]}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
