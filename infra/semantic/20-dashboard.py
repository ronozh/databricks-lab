"""
Create or update the HR workforce AI/BI dashboard, from code.

    python3 infra/semantic/20-dashboard.py            # the catalog from .envrc
    python3 infra/semantic/20-dashboard.py hr_review
    python3 infra/semantic/20-dashboard.py --show     # print the dashboard id

Idempotent -- and the naive version was NOT. `lakeview list` is eventually consistent, so
a second run seconds later did not find the dashboard just created, took the create path,
and FAILED with "A node with name 'HR Workforce' already exists under the specified
parent". The only thing preventing a real duplicate was the workspace filesystem's name
uniqueness. The created id is now cached in .dashboard-id beside this script and preferred
over the listing. A TRASHED dashboard is also detected -- `lakeview list` keeps reporting
it ACTIVE, so a PATCH against it fails with an unhelpful lifecycle error.

EVERY DATASET QUERIES THE METRIC VIEW, never a silver or gold table. That is the
whole point of J19 ("downstream BI or AI workloads"): if a dashboard computes its own
headcount, the semantic layer has failed at its one job and the tile can disagree with
Genie about the same word. Here both consume measure(), so they cannot drift.

It also inherits governance for free -- row filtering and column masks resolve per
VIEWER through the metric view, so two people opening the same dashboard legitimately
see different totals. A tile labelled "company total" would therefore be a lie for
some viewers; the labels below say which measure, not "the" anything.
"""
import argparse, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "infra"))
import dbsql  # noqa: E402

# The catalog is IN THE NAME, for the same reason as the Genie space: a dashboard is a
# WORKSPACE object, so without this `20-dashboard.py hr_review` repointed PRODUCTION's
# dashboard at the review catalog.
def name_for(cat):
    primary = os.environ.get("DBX_CATALOG", "hr")
    return "HR Workforce" if cat == primary else f"HR Workforce ({cat})"


def cli(*args, expect_json=True):
    rc, out, err = dbsql.cli(*args, profile=os.environ.get("DBX_PROFILE", "free"))
    if rc:
        sys.exit(f"failed: databricks {' '.join(args[:3])}\n{err or out}")
    return json.loads(out) if expect_json and out else out


ID_CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".dashboard-id")


def _cached_id(cat):
    try:
        for line in open(ID_CACHE):
            c, v = line.strip().split("=", 1)
            if c == cat:
                return v
    except OSError:
        pass
    return None


def _cache_id(cat, did):
    lines = {}
    try:
        for line in open(ID_CACHE):
            c, v = line.strip().split("=", 1)
            lines[c] = v
    except OSError:
        pass
    lines[cat] = did
    with open(ID_CACHE, "w") as f:
        for c, v in sorted(lines.items()):
            f.write(f"{c}={v}\n")


def _state(did):
    """ACTIVE / TRASHED / None. `lakeview list` lies about trashed ones."""
    rc, out, _ = dbsql.cli("api", "get", f"/api/2.0/lakeview/dashboards/{did}",
                           profile=os.environ.get("DBX_PROFILE", "free"))
    if rc or not out:
        return None
    try:
        return json.loads(out).get("lifecycle_state", "ACTIVE")
    except ValueError:
        return None


def find(cat):
    """Cached id first -- the listing lags writes by minutes."""
    did = _cached_id(cat)
    if did and _state(did):
        return did
    want = name_for(cat)
    for d in cli("lakeview", "list", "-o", "json") or []:
        if d.get("display_name") == want:
            _cache_id(cat, d["dashboard_id"])
            return d["dashboard_id"]
    return None


def counter(name, dataset, field, title, fmt=None):
    enc = {"value": {"fieldName": field, "displayName": title}}
    return {
        "widget": {
            "name": name,
            "queries": [{"name": f"q_{name}", "query": {
                "datasetName": dataset, "fields": [{"name": field, "expression": f"`{field}`"}],
                "disaggregated": False}}],
            "spec": {"version": 2, "widgetType": "counter", "encodings": enc},
        }
    }


def bar(name, dataset, x, y, title):
    return {
        "widget": {
            "name": name,
            "queries": [{"name": f"q_{name}", "query": {
                "datasetName": dataset,
                "fields": [{"name": x, "expression": f"`{x}`"},
                           {"name": y, "expression": f"`{y}`"}],
                "disaggregated": False}}],
            "spec": {"version": 3, "widgetType": "bar",
                     "encodings": {"x": {"fieldName": x, "scale": {"type": "categorical"},
                                         "displayName": x},
                                   "y": {"fieldName": y, "scale": {"type": "quantitative"},
                                         "displayName": title}}},
        }
    }


def serialized(cat):
    mv = f"{cat}.gold.mv_hr_workforce"
    return json.dumps({
        "datasets": [
            {"name": "totals", "displayName": "Headcount, three ways",
             "queryLines": [
                 "SELECT measure(headcount_people)   AS headcount_people,\n",
                 "       measure(headcount_fte)      AS headcount_fte,\n",
                 "       measure(headcount_fulltime) AS headcount_fulltime\n",
                 f"FROM {mv}"]},
            {"name": "by_dept", "displayName": "By department",
             "queryLines": [
                 "SELECT `Department` AS department,\n",
                 "       measure(headcount_people) AS headcount_people,\n",
                 "       measure(headcount_fte)    AS headcount_fte\n",
                 f"FROM {mv}\n",
                 "GROUP BY `Department`\n",
                 "ORDER BY headcount_people DESC"]},
            {"name": "by_type", "displayName": "By employment type",
             "queryLines": [
                 "SELECT `Employment type` AS employment_type,\n",
                 "       measure(headcount_people) AS headcount_people\n",
                 f"FROM {mv}\n",
                 "GROUP BY `Employment type`\n",
                 "ORDER BY headcount_people DESC"]},
        ],
        "pages": [{
            "name": "workforce",
            "displayName": "Workforce",
            "layout": [
                {"position": {"x": 0, "y": 0, "width": 6, "height": 2},
                 **counter("c_people", "totals", "headcount_people", "People (headcount_people)")},
                {"position": {"x": 0, "y": 2, "width": 6, "height": 2},
                 **counter("c_fte", "totals", "headcount_fte", "FTE (headcount_fte)")},
                {"position": {"x": 0, "y": 4, "width": 6, "height": 2},
                 **counter("c_ft", "totals", "headcount_fulltime", "Full-time (headcount_fulltime)")},
                {"position": {"x": 0, "y": 6, "width": 6, "height": 6},
                 **bar("b_dept", "by_dept", "department", "headcount_people",
                       "People by department (headcount_people)")},
                {"position": {"x": 0, "y": 12, "width": 6, "height": 5},
                 **bar("b_type", "by_type", "employment_type", "headcount_people",
                       "People by employment type (headcount_people)")},
            ],
        }],
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog", nargs="?")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()
    cat = a.catalog or os.environ.get("DBX_CATALOG")
    if not cat:
        sys.exit("give a catalog or set DBX_CATALOG")

    name = name_for(cat)
    existing = find(cat)
    if a.show:
        print(existing or "")
        return

    body = {
        "display_name": name,
        "warehouse_id": dbsql.warehouse_id(os.environ.get("DBX_PROFILE", "free")),
        "serialized_dashboard": serialized(cat),
    }
    if existing:
        if _state(existing) == "TRASHED":
            sys.exit(f"dashboard {existing} is TRASHED -- restore it in the UI, or remove "
                     f"its line from {ID_CACHE} and rename/purge the old one. A PATCH "
                     f"against a trashed dashboard fails with an unhelpful lifecycle error.")
        cli("api", "patch", f"/api/2.0/lakeview/dashboards/{existing}",
            "--json", json.dumps(body))
        print(f"updated dashboard {existing}  ({name} -> {cat})")
    else:
        r = cli("api", "post", "/api/2.0/lakeview/dashboards", "--json", json.dumps(body))
        existing = r.get("dashboard_id")
        _cache_id(cat, existing)
        print(f"created dashboard {existing}  ({name} -> {cat})")

    # Publish WITHOUT embedded credentials. The API default is embed_credentials=true,
    # which runs every viewer's tiles as the PUBLISHER -- so current_user() in
    # filter_dept resolves to the publisher and every viewer sees the publisher's rows
    # and unmasked salaries. That is exactly the bypass S5 exists to prevent,
    # reintroduced one click later. An unpublished draft is also unopenable by anyone
    # else, which is why the per-viewer governance claim was previously untested.
    cli("api", "post", f"/api/2.0/lakeview/dashboards/{existing}/published",
        "--json", json.dumps({"embed_credentials": False,
                              "warehouse_id": body["warehouse_id"]}))
    print(f"published {existing} with embed_credentials=false (per-viewer governance)")


if __name__ == "__main__":
    main()
