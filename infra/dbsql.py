"""
Run SQL against the lab's Databricks SQL warehouse from the shell.

    python3 infra/dbsql.py "SELECT 1"
    python3 infra/dbsql.py --file setup.sql
    python3 infra/dbsql.py --as hr_analyst "SELECT * FROM hr.gold.gold_hr_headcount_by_department"

Uses the Databricks CLI for auth, so there is no token in this repo and no SDK to
install. The warehouse is discovered rather than hard-coded -- see D4.
"""
import argparse, json, os, re, subprocess, sys, time

SECRETS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       ".env.secret")


def cli(*args, profile="free", env=None):
    """profile=None means authenticate from `env` instead of ~/.databrickscfg."""
    cmd = ["databricks", *args]
    if profile:
        cmd += ["--profile", profile]
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def _host(profile="free"):
    if os.environ.get("DBX_HOST"):
        return "https://" + os.environ["DBX_HOST"].replace("https://", "")
    rc, out, _ = cli("auth", "describe", "-o", "json", profile=profile)
    if rc:
        sys.exit("cannot determine workspace host; set DBX_HOST")
    return json.loads(out)["details"]["host"]


def sp_env(alias, profile="free"):
    """OAuth M2M environment for a service principal named in .env.secret.

    Reads SP_<ALIAS>_CLIENT_ID / SP_<ALIAS>_CLIENT_SECRET. The secret never
    reaches argv -- it is passed to the child process through its environment
    only, so it stays out of `ps` output and out of this repo.
    """
    key = alias.upper().replace("-", "_")
    creds = {}
    try:
        for line in open(SECRETS):
            m = re.match(r"\s*(?:export\s+)?([A-Za-z0-9_]+)\s*=\s*(.*)", line)
            if m:
                creds[m.group(1)] = m.group(2).strip().strip("'\"")
    except FileNotFoundError:
        sys.exit(f"{SECRETS} not found -- run infra/governance/00-principals.sh")
    # Accept both spellings: SP_<ALIAS>_* as minted by 00-principals.sh, and a
    # bare <ALIAS>_* so the Phase 1 pipeline principal (DBX_CLIENT_ID) is usable
    # as `--as dbx` without duplicating its secret into a second variable.
    cid = creds.get(f"SP_{key}_CLIENT_ID") or creds.get(f"{key}_CLIENT_ID")
    sec = creds.get(f"SP_{key}_CLIENT_SECRET") or creds.get(f"{key}_CLIENT_SECRET")
    if not (cid and sec):
        sys.exit(f"SP_{key}_CLIENT_ID / _SECRET missing from .env.secret")
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("DATABRICKS_")}
    env.update(DATABRICKS_HOST=_host(profile), DATABRICKS_CLIENT_ID=cid,
               DATABRICKS_CLIENT_SECRET=sec, DATABRICKS_AUTH_TYPE="oauth-m2m")
    return env


def warehouse_id(profile, env=None):
    rc, out, err = cli("warehouses", "list", "-o", "json", profile=profile, env=env)
    if rc or not out:
        sys.exit(f"cannot list warehouses: {err or out}")
    whs = json.loads(out)
    if not whs:
        sys.exit("no SQL warehouse in this workspace")
    return (([w for w in whs if w.get("state") == "RUNNING"] or whs)[0])["id"]


UNEXPANDED = "${"


def run(stmt, profile="free", wh=None, catalog=None, timeout=900, env=None):
    """Returns (ok, result_dict) or (False, error_string)."""
    # Refuse a statement still carrying a shell placeholder. os.path.expandvars
    # leaves an UNSET variable in place verbatim, so running a governance step by
    # hand instead of through apply.sh inserted the literal string
    # '${BIZ_ANALYST_APP_ID}' into the access map as a principal -- accepted by the
    # database, matching nobody, and silently denying the role it was meant to grant.
    # Cheap guard against a whole class of silent misconfiguration.
    if UNEXPANDED in stmt:
        bad = stmt[stmt.index(UNEXPANDED):][:40]
        return False, (f"refusing: statement contains an unexpanded variable near "
                       f"'{bad}' -- run it through infra/governance/apply.sh")
    wh = wh or warehouse_id(profile, env)
    body = {"warehouse_id": wh, "statement": stmt, "wait_timeout": "30s"}
    if catalog:
        body["catalog"] = catalog
    rc, out, err = cli("api", "post", "/api/2.0/sql/statements",
                       "--json", json.dumps(body), profile=profile, env=env)
    if rc:
        return False, err or out
    r = json.loads(out)
    sid, waited = r.get("statement_id"), 0
    # The API returns once wait_timeout elapses; long statements need polling.
    while r.get("status", {}).get("state") in ("PENDING", "RUNNING") and waited < timeout:
        time.sleep(2)
        waited += 2
        rc, out, err = cli("api", "get", f"/api/2.0/sql/statements/{sid}",
                           profile=profile, env=env)
        if rc:
            return False, err
        r = json.loads(out)
    st = r.get("status", {})
    if st.get("state") != "SUCCEEDED":
        return False, json.dumps(st.get("error", st))
    return True, r.get("result", {})


def split_statements(text):
    """Naive ';' splitter that drops line comments and empty statements.

    Known limits, both of which fail loudly rather than silently: a ';' inside a
    string literal at end of line splits the statement, and a multi-line comment
    (/* */) is not recognised. A trailing comment AFTER a ';' is handled.
    """
    out, buf = [], []
    for line in text.splitlines():
        if line.strip().startswith("--"):
            continue
        # `SELECT 1; -- note` used to concatenate with the next statement, because the
        # line does not END with ';'. Strip the trailing comment first.
        stripped = re.sub(r";\s*--.*$", ";", line.rstrip())
        if stripped.endswith(";"):
            line = stripped
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
    ap.add_argument("--as", dest="as_sp", metavar="ALIAS",
                    help="run as the service principal named in .env.secret")
    a = ap.parse_args()

    env, profile = None, a.profile
    if a.as_sp:
        env, profile = sp_env(a.as_sp, a.profile), None

    if a.file:
        stmts = split_statements(open(a.file).read())
    elif a.statement:
        stmts = [a.statement]
    else:
        sys.exit("give a statement or --file")

    wh = warehouse_id(profile, env)
    failed = 0
    for s in stmts:
        label = " ".join(s.split())[:88]
        ok, res = run(s, profile=profile, wh=wh, catalog=a.catalog, env=env)
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
