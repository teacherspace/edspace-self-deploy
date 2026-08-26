#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Check config/contract.yaml against the environment the app actually reads.

`make gen` keeps the generated surfaces in step with the contract, but nothing
kept the contract in step with the *application*. This does: it reads the app
repository's configuration wiring and reports both directions of drift.

  uv run scripts/check-contract-parity.py --app-repo ../../edspace

A variable the app reads must either appear under `vars:` in the contract or
match an entry under `excluded:` (with a reason). Anything else is reported.

This is a maintainer task, not a CI gate — CI has no checkout of the app repo.
Run it whenever the app's configuration changes, and before cutting a release.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "config" / "contract.yaml"

# Configuration wiring, in the app repo. Files outside this set are still
# scanned for explicit `System.get_env("NAME")` calls; these are additionally
# scanned for bare "NAME" literals, because they hold the lookup TABLES that
# feed indirect reads (Repo.PoolConfig's @env, the endpoint's socket-drainer
# map, runtime.exs's chat-tool switch list).
WIRING_FILES = (
    "config/runtime.exs",
    "config/config.exs",
    "config/prod.exs",
    "lib/edspace/repo/pool_config.ex",
    "lib/edspace_web/endpoint.ex",
    "lib/langfuse/client.ex",
    "rel/env.sh.eex",
)

# Contracted variables that no scan of the app source will find, because the
# Erlang/OTP release boot scripts consume them before any application code
# runs. mix generates those scripts at build time, so they exist in no file
# here. Keep this list short and justified.
RUNTIME_CONSUMED = {
    "RELEASE_DISTRIBUTION",
    "RELEASE_NODE",
    "RELEASE_COOKIE",
}

SEARCH_ROOTS = ("config", "lib", "rel", "priv/repo/migrations")

EXPLICIT = re.compile(r'System\.(?:get_env|fetch_env!?)\(\s*"([A-Z][A-Z0-9_]{2,})"')
LITERAL = re.compile(r'"([A-Z][A-Z0-9_]{2,})"')
COMMENT = re.compile(r"(?m)^\s*#.*$")

# Names that look like env vars in the wiring files but are not read as one:
# prose fragments, prefixes named in comments, and tooling vars.
NOT_ENV = {
    "NODE_PATH",              # esbuild/tailwind asset pipeline, not app config
    "OTEL_EXPORTER_OTLP_",    # a prefix named in prose, deliberately unset
    "SOME_APP_SSL_CERT_PATH",  # Phoenix's commented-out HTTPS example
    "SOME_APP_SSL_KEY_PATH",
}


def read_contract() -> tuple[list[dict], list[dict]]:
    data = yaml.safe_load(CONTRACT.read_text())
    return data.get("vars") or [], data.get("excluded") or []


def excluded_reason(name: str, rules: list[dict]) -> str | None:
    for rule in rules:
        if "name" in rule and rule["name"] == name:
            return rule.get("reason", "")
        if "prefix" in rule and name.startswith(rule["prefix"]):
            return rule.get("reason", "")
    return None


def scan(app_repo: Path) -> dict[str, set[str]]:
    """Map each variable name to the app-relative files that read it."""
    found: dict[str, set[str]] = {}

    def record(name: str, rel: str) -> None:
        if name not in NOT_ENV:
            found.setdefault(name, set()).add(rel)

    for root in SEARCH_ROOTS:
        base = app_repo / root
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if path.suffix not in (".ex", ".exs", ".eex") or not path.is_file():
                continue
            rel = str(path.relative_to(app_repo))
            text = path.read_text(errors="replace")
            for m in EXPLICIT.finditer(text):
                record(m.group(1), rel)
            if rel in WIRING_FILES:
                for m in LITERAL.finditer(COMMENT.sub("", text)):
                    record(m.group(1), rel)

    for extra in ("rel/env.sh.eex", "Dockerfile"):
        path = app_repo / extra
        if path.is_file():
            text = path.read_text(errors="replace")
            for m in re.finditer(r"\$\{([A-Z][A-Z0-9_]{2,}):", text):
                record(m.group(1), extra)
    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app-repo", required=True, type=Path,
                    help="path to a checkout of the EdSpace application repo")
    args = ap.parse_args()

    app_repo = args.app_repo.expanduser().resolve()
    if not (app_repo / "config" / "runtime.exs").is_file():
        print(f"not an EdSpace app checkout: {app_repo}", file=sys.stderr)
        return 2

    variables, exclusions = read_contract()
    contracted = {v["name"] for v in variables}
    found = scan(app_repo)

    uncovered = {
        name: sorted(files)
        for name, files in sorted(found.items())
        if name not in contracted and excluded_reason(name, exclusions) is None
    }

    # The reverse direction. Deploy-layer variables are read by compose or the
    # packaging, never by the app, so their absence here is expected.
    unread = sorted(
        v["name"]
        for v in variables
        if v["name"] not in found
        and v["category"] != "deploy"
        and v["name"] not in RUNTIME_CONSUMED
    )

    if uncovered:
        print("Read by the app, missing from the contract:\n")
        for name, files in uncovered.items():
            print(f"  {name}\n      {', '.join(files)}")
        print(
            "\nAdd each to `vars:` in config/contract.yaml (then `make gen`), "
            "or to `excluded:` with a reason.\n"
        )

    if unread:
        print("In the contract, no longer read by the app:\n")
        for name in unread:
            print(f"  {name}")
        print(
            "\nEither the app dropped it — remove it and `make gen` — or it is "
            "read somewhere this scan does not look; widen WIRING_FILES.\n"
        )

    if not uncovered and not unread:
        print(f"contract matches {app_repo.name}: {len(contracted)} variables")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
