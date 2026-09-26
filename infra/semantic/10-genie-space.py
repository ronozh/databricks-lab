"""
Create or update the HR Genie space, from code rather than by clicking.

    python3 infra/semantic/10-genie-space.py            # the catalog from .envrc
    python3 infra/semantic/10-genie-space.py hr_review
    python3 infra/semantic/10-genie-space.py --show      # print the space id and exit

Idempotent, the hard way. Two traps, both found by review after the naive version
looked like it worked:

  * `genie list-spaces` is EVENTUALLY CONSISTENT. A space created seconds ago is not
    listed, so a find-by-title on an immediate re-run misses it and creates a second
    one -- and the API then silently RENAMES the duplicate ("... 2026-09-26 11:48:37"),
    so its title no longer matches and it can never be found or cleaned up again.
    Mitigation: the created id is cached in .genie-space-id next to this script and
    preferred over the listing.
  * Passing the `etag` made the update path a PERMANENT NO-OP. With an etag, the API
    accepts the PATCH only if the submitted body is byte-identical to what is stored;
    any real change is rejected with "Space configuration has been modified since this
    export was taken" -- forever, because the etag is a content hash of the stored
    export, not a version counter. So every "updated" this script used to print was a
    write that did not happen. It now PATCHes without an etag and verifies the change
    landed by reading it back.

WHY THE SPACE POINTS AT A METRIC VIEW AND NOT AT TABLES
Genie will answer from whatever it is given. Pointed at silver it invents its own
aggregation, and the recorded baseline shows what that costs: asked "how many
employees are currently employed" it answered 478 via COUNT(*) -- correct for one of
three defensible definitions, chosen silently, with nothing in the reply revealing
that 447.0 and 416 were equally available. Pointed at the metric view it has to use
a NAMED measure, so the definition is in the answer.

The instructions below are the other half. They are not decoration: they are what
turns "pick one" into "say which, or ask".
"""
import argparse, hashlib, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "infra"))
import dbsql  # noqa: E402

# The catalog is IN THE TITLE. A Genie space is a WORKSPACE-level singleton, but this
# script takes a catalog argument -- so without this, `10-genie-space.py hr_review`
# silently repointed PRODUCTION's space at the review catalog. There is no
# review-env.sh-style guard on a workspace object, and verify.sh skips exactly the
# assertion that would have noticed.
def title_for(cat):
    primary = os.environ.get("DBX_CATALOG", "hr")
    return "HR Workforce" if cat == primary else f"HR Workforce ({cat})"
DESCRIPTION = (
    "Workforce questions for the HR domain, answered through the governed semantic "
    "layer. Headcount has three defensible definitions here and they disagree -- ask "
    "which one you want, or the answer will say which one it used."
)

# The instruction set IS the governance of meaning. P4: the data team facilitates and
# does not decide -- so the space is told to surface the ambiguity, never to resolve it
# by picking a favourite.
# The instruction set IS the governance of meaning. P4: the data team facilitates and does not
# decide -- so the space is told to surface the ambiguity, never to resolve it by picking a
# favourite.
#
# A LIST, one bullet per element. `content` is an array of SEPARATE instructions: passing a
# single multi-line string stored only the FIRST bullet and silently dropped the other seven,
# leaving the space without the rule that makes the headline experiment work -- while the
# script printed success. Measured: 174 of 1485 characters survived.
#
# DELIBERATELY CONTAINS NO NUMBERS. The first version wrote "(478)", "(447.0)", "(416)" beside
# the measure names as literals. Nothing derived them from the view, so if the roster moved,
# Genie would recite stale figures from its prompt while the view and the dashboard moved --
# the one place a semantic layer can be shadowed by a copy of its own output. Measure NAMES
# carry the meaning; the values are the view's job.
INSTRUCTIONS = [
    "NEVER state a headcount figure from memory or from these instructions -- always query "
    "the view. Any number written here would be stale the moment the roster changes.",

    "Always answer workforce questions from the metric view {cat}.gold.mv_hr_workforce using "
    "measure(<name>). Never write your own COUNT or SUM over the silver tables.",

    "HEADCOUNT IS AMBIGUOUS AND YOU MUST NOT SILENTLY CHOOSE. Three measures exist and they "
    "give different answers: measure(headcount_people) is one row per employed person; "
    "measure(headcount_fte) is FTE-weighted, where non-full-time counts 0.5; "
    "measure(headcount_fulltime) counts full-time employees only.",

    "If a question says how many people, headcount, staff or employees WITHOUT saying which "
    "basis, either ask which definition is meant, or answer with all three clearly labelled. "
    "Do not return a single bare number.",

    "Whenever you return a headcount, NAME the measure you used in the answer.",

    "salary_total and salary_avg are restricted and return NULL unless the caller is an HR "
    "steward. A NULL salary is a permission outcome, not missing data -- say so rather than "
    "reporting zero or omitting the column.",

    "Row visibility is per-user: a caller limited to some departments sees only those, so "
    "totals legitimately differ between users. Never describe a total as the company total "
    "unless the caller can see every department.",

    "Currently employed is already applied by the view's filter. Do not add your own "
    "employment filter.",
]

SAMPLE_QUESTIONS = [
    "How many people work here?",                       # deliberately underspecified
    "What is the FTE-weighted headcount by department?",
    "Which departments have the most people managers?",
    "Compare headcount by employment type",
    "How many full-time employees are in each cost centre?",
]


def cli(*args, expect_json=True):
    rc, out, err = dbsql.cli(*args, profile=os.environ.get("DBX_PROFILE", "free"))
    if rc:
        sys.exit(f"failed: databricks {' '.join(args[:3])}\n{err or out}")
    return json.loads(out) if expect_json and out else out


ID_CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".genie-space-id")


def _cached_id(cat):
    try:
        for line in open(ID_CACHE):
            c, sid = line.strip().split("=", 1)
            if c == cat:
                return sid
    except OSError:
        pass
    return None


def _cache_id(cat, sid):
    lines = {}
    try:
        for line in open(ID_CACHE):
            c, v = line.strip().split("=", 1)
            lines[c] = v
    except OSError:
        pass
    lines[cat] = sid
    with open(ID_CACHE, "w") as f:
        for c, v in sorted(lines.items()):
            f.write(f"{c}={v}\n")


def find_space(cat):
    """The cached id first, because the listing lags behind writes by minutes."""
    sid = _cached_id(cat)
    if sid:
        rc, out, _ = dbsql.cli("api", "get", f"/api/2.0/genie/spaces/{sid}",
                               profile=os.environ.get("DBX_PROFILE", "free"))
        if rc == 0:
            return sid                      # still there
    want = title_for(cat)
    # `list-spaces` is paginated and the CLI does not follow next_page_token, so walk it.
    token, seen = None, 0
    while True:
        args = ["genie", "list-spaces", "-o", "json"]
        if token:
            args += ["--page-token", token]
        page = cli(*args)
        for sp in page.get("spaces", []) or []:
            seen += 1
            if sp.get("title") == want:
                _cache_id(cat, sp["space_id"])
                return sp["space_id"]
        token = page.get("next_page_token")
        if not token or seen > 500:
            return None


def oid(*parts):
    """A stable id for a space element.

    The API demands a lowercase 32-hex id for every SAMPLE QUESTION and rejects an
    absent or malformed one. (An absent INSTRUCTION-block id is accepted and the
    server mints one -- only a malformed one is refused, so the original comment
    here overstated it.)

    Deriving the id from content keeps re-runs stable: PATCH replaces
    serialized_space wholesale, so random ids would not accumulate duplicates, but
    they WOULD make every run a spurious change and defeat the no-op check in main().
    """
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:32]


def serialized(cat):
    return json.dumps({
        "version": 2,
        "data_sources": {"tables": [{"identifier": f"{cat}.gold.mv_hr_workforce"}]},
        "instructions": {
            "text_instructions": [
                {"id": oid("instructions", cat),
                 "content": [b.format(cat=cat) for b in INSTRUCTIONS]}
            ]
        },
        "config": {
            "sample_questions": [
                {"id": oid("q", q), "question": [q]} for q in SAMPLE_QUESTIONS
            ]
        },
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog", nargs="?")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()
    cat = a.catalog or os.environ.get("DBX_CATALOG")
    if not cat:
        sys.exit("give a catalog or set DBX_CATALOG")

    title = title_for(cat)
    existing = find_space(cat)
    if a.show:
        print(existing or "")
        return

    want = serialized(cat)
    body = {
        "warehouse_id": dbsql.warehouse_id(os.environ.get("DBX_PROFILE", "free")),
        "title": title,
        "description": DESCRIPTION,
        "serialized_space": want,
    }

    def norm(spec):
        """Reduce a space spec to what we actually control, so it can be compared.

        Three normalisations, each needed because the server rewrites what it stores:
          * `content` arrays come back JOINED into a single element, so compare the
            concatenated text rather than the list shape;
          * `content` is concatenated with NO separator, so compare with all whitespace
            stripped rather than guessing the join character;
          * sample questions come back REORDERED, so compare them as a set;
          * key order and whitespace differ, so never compare raw JSON text.
        Without this the script reported "did not change" on every run -- and on one run
        that message was RIGHT and I nearly relaxed the check instead of investigating.
        """
        d = json.loads(spec) if isinstance(spec, str) else (spec or {})
        # Join with NOTHING and then strip every space: the server concatenates the
        # content array with no separator, so joining with " " differed by exactly one
        # character per bullet (1438 vs 1431 for eight of them). Comparing
        # whitespace-insensitively removes a whole class of false "it changed".
        instr = "".join(
            "".join(b.get("content", []))
            for b in d.get("instructions", {}).get("text_instructions", []))
        return {
            "version": d.get("version"),
            "tables": sorted(t.get("identifier", "")
                             for t in d.get("data_sources", {}).get("tables", [])),
            "instructions": re.sub(r"\s+", "", instr),
            "questions": sorted(q.get("question", [""])[0]
                                for q in d.get("config", {}).get("sample_questions", [])),
        }

    def same(stored):
        try:
            return norm(stored) == norm(want)
        except (ValueError, TypeError, AttributeError):
            return False

    if existing:
        cur = cli("api", "get",
                  f"/api/2.0/genie/spaces/{existing}?include_serialized_space=true")
        if same(cur.get("serialized_space")) and cur.get("title") == title:
            print(f"genie space {existing} already matches  ({title} -> {cat})")
            return
        # NO etag: with one, the API accepts only a byte-identical body, which makes
        # every real change a permanent failure. Drift is detected above instead.
        cli("api", "patch", f"/api/2.0/genie/spaces/{existing}", "--json", json.dumps(body))
        check = cli("api", "get",
                    f"/api/2.0/genie/spaces/{existing}?include_serialized_space=true")
        if not same(check.get("serialized_space")):
            sys.exit(f"PATCH reported success but {existing} did not change -- refusing "
                     f"to claim an update that did not happen")
        print(f"updated genie space {existing}  ({title} -> {cat})")
    else:
        r = cli("api", "post", "/api/2.0/genie/spaces", "--json", json.dumps(body))
        sid = r.get("space_id")
        _cache_id(cat, sid)     # so an immediate re-run finds it despite the listing lag
        print(f"created genie space {sid}  ({title} -> {cat})")


if __name__ == "__main__":
    main()
