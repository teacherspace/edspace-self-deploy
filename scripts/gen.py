#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Generate deployment surfaces from config/contract.yaml.

Outputs (committed to the repo; CI verifies freshness):
  compose/.env.example            user-facing env template
  chart/edspace/values.schema.json  base schema + env/envSecret validation
  docs/env-vars.md                reference table

Usage:
  uv run scripts/gen.py           regenerate files in place
  uv run scripts/gen.py --check   exit 1 with a diff if any file is stale
"""

from __future__ import annotations

import difflib
import json
import sys
import textwrap
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "config" / "contract.yaml"
SCHEMA_BASE = ROOT / "config" / "values.schema.base.json"

OUT_ENV_EXAMPLE = ROOT / "compose" / ".env.example"
OUT_VALUES_SCHEMA = ROOT / "chart" / "edspace" / "values.schema.json"
OUT_DOCS = ROOT / "docs" / "env-vars.md"

TIERS = {"core", "advanced", "internal"}
SOURCES = {"user", "computed", "fixed"}
TYPES = {"string", "integer", "boolean", "enum"}

# Computed/fixed vars must actually be produced by the packaging layers;
# this table is asserted so the contract can't silently promise a var
# nothing composes. Update alongside chart/compose/managed-app changes.
PRODUCED_VARS = {
    "DATABASE_URL": "chart secret/deployment env, compose environment, managed-app ACA secret",
    "DNS_CLUSTER_QUERY": "chart deployment env (clustering.enabled)",
    "RELEASE_DISTRIBUTION": "chart deployment env (clustering.enabled)",
    "RELEASE_NODE": "chart deployment env (clustering.enabled)",
    "RELEASE_COOKIE": "chart generated/explicit secret (clustering.enabled)",
    "PHX_SERVER": "app image ENV",
    "PORT": "app image ENV (matches chart targetPort / compose port)",
}

# These variables have dedicated chart values because templates compose them,
# create resources for them, or route them to specific Secrets. Allowing the
# same names in env/envSecret would render duplicate YAML keys with ambiguous
# precedence, so the generated schema rejects that configuration.
CHART_STRUCTURED_VARS = {
    "PHX_HOST",
    "PHX_CHECK_ORIGIN",
    "SECRET_KEY_BASE",
    "TOKEN_SIGNING_SECRET",
    "EDSPACE_FILE_STORAGE_ADAPTER",
    "EDSPACE_FILE_STORAGE_ROOT",
    "AZURE_STORAGE_ACCOUNT",
    "AZURE_STORAGE_CONTAINER",
    "AZURE_STORAGE_KEY",
    "EDSPACE_LLM_PROVIDER",
    "EDSPACE_LLM_API_KEY",
    "EDSPACE_LLM_BASE_URL",
    "EDSPACE_LLM_API_VERSION",
    "EDSPACE_LLM_TEXT_MODEL",
    "EDSPACE_LLM_TEXT_DEPLOYMENT",
    "EDSPACE_LLM_SMALL_MODEL",
    "EDSPACE_LLM_SMALL_DEPLOYMENT",
    "EDSPACE_LLM_EMBEDDING_MODEL",
    "EDSPACE_LLM_EMBEDDING_DEPLOYMENT",
    "MAILER_ADAPTER",
    "MAILER_FROM_EMAIL",
    "MAILER_FROM_NAME",
    "MAILPACE_API_KEY",
    "MAILER_SMTP_RELAY",
    "MAILER_SMTP_PORT",
    "MAILER_SMTP_USERNAME",
    "MAILER_SMTP_PASSWORD",
    "MAILER_SMTP_SSL",
    "MAILER_SMTP_TLS",
    "MAILER_SMTP_AUTH",
    "MAILER_SMTP_TLS_VERIFY",
    "MAILER_SMTP_CACERTFILE",
    "MAILER_SMTP_NO_MX_LOOKUPS",
}

GENERATED_BANNER = "GENERATED FILE - edit config/contract.yaml and run `make gen`."


class ContractError(Exception):
    pass


def load_contract() -> tuple[list[dict], list[dict]]:
    data = yaml.safe_load(CONTRACT.read_text())
    categories = data.get("categories") or []
    variables = data.get("vars") or []
    excluded = data.get("excluded") or []
    errors: list[str] = []

    # Deliberate omissions, consumed by scripts/check-contract-parity.py.
    # Validated here so a malformed entry fails at `make gen` rather than
    # silently widening what the parity check ignores.
    for i, rule in enumerate(excluded):
        if not isinstance(rule, dict) or bool(rule.get("name")) == bool(rule.get("prefix")):
            errors.append(f"excluded[{i}]: needs exactly one of `name` or `prefix`")
            continue
        if not rule.get("reason"):
            errors.append(f"excluded[{i}]: missing reason")

    cat_ids = [c["id"] for c in categories]
    if len(set(cat_ids)) != len(cat_ids):
        errors.append("duplicate category ids")

    seen: set[str] = set()
    for v in variables:
        name = v.get("name", "<unnamed>")
        if name in seen:
            errors.append(f"{name}: duplicate var")
        seen.add(name)
        if v.get("category") not in cat_ids:
            errors.append(f"{name}: unknown category {v.get('category')!r}")
        if v.get("tier") not in TIERS:
            errors.append(f"{name}: tier must be one of {sorted(TIERS)}")
        if v.get("source") not in SOURCES:
            errors.append(f"{name}: source must be one of {sorted(SOURCES)}")
        if v.get("type") not in TYPES:
            errors.append(f"{name}: type must be one of {sorted(TYPES)}")
        if (v.get("type") == "enum") != bool(v.get("enum")):
            errors.append(f"{name}: `enum` list required iff type is enum")
        if not isinstance(v.get("secret"), bool):
            errors.append(f"{name}: secret must be a bool")
        if not v.get("description"):
            errors.append(f"{name}: missing description")
        req = v.get("required", False)
        if not (isinstance(req, bool) or isinstance(req, dict)):
            errors.append(f"{name}: required must be bool or {{chart,compose}} map")
        rw = v.get("required_when")
        if rw is not None and not (isinstance(rw, str) and rw.strip()):
            errors.append(f"{name}: required_when must be a non-empty string")
        if rw and req is True:
            errors.append(
                f"{name}: required_when contradicts required: true "
                "(use a per-context map, or drop one of them)"
            )
        if v.get("secret") and v.get("example"):
            errors.append(f"{name}: secret vars must not carry an example value")
        if v.get("source") in ("computed", "fixed") and name not in PRODUCED_VARS:
            errors.append(
                f"{name}: source={v['source']} but no producer registered in gen.py"
            )

    for name in sorted(CHART_STRUCTURED_VARS - seen):
        errors.append(f"{name}: chart structured var is missing from the contract")

    for rule in excluded:
        if not isinstance(rule, dict):
            continue
        clash = sorted(
            n
            for n in seen
            if n == rule.get("name")
            or (rule.get("prefix") and n.startswith(rule["prefix"]))
        )
        if clash:
            errors.append(
                f"excluded {rule.get('name') or rule['prefix']!r} also appears "
                f"in vars: {', '.join(clash)}"
            )

    if errors:
        raise ContractError("contract.yaml invalid:\n  " + "\n  ".join(errors))
    return categories, variables


def default_for(v: dict, context: str) -> str | None:
    d = v.get("default")
    if d is None:
        return None
    if isinstance(d, dict):
        val = d.get(context, d.get("app"))
    else:
        val = d
    if val is None:
        return None
    if isinstance(val, bool):
        return "true" if val else "false"
    return str(val)


def required_for(v: dict, context: str) -> bool:
    req = v.get("required", False)
    if isinstance(req, dict):
        return bool(req.get(context, False))
    return bool(req)


def wrap_comment(text: str, prefix: str = "# ") -> list[str]:
    return [prefix + line for line in textwrap.wrap(" ".join(text.split()), width=76)]


# --------------------------------------------------------------- .env.example
def gen_env_example(categories: list[dict], variables: list[dict]) -> str:
    lines = [
        f"# {GENERATED_BANNER}",
        "# Environment template for the Docker Compose deployment.",
        "#",
        "# Uncommented entries are required; commented entries are optional",
        "# settings shown with their defaults. The app treats a set-but-empty",
        "# variable as SET, so only uncomment a line when giving it a value.",
        "# See docs/env-vars.md for the full reference.",
    ]
    for cat in categories:
        cat_vars = [
            v
            for v in variables
            if v["category"] == cat["id"]
            and v["source"] == "user"
            and v["tier"] in ("core", "advanced")
        ]
        if not cat_vars:
            continue
        lines += ["", f"## {cat['title']}", ""]
        for v in cat_vars:
            lines += wrap_comment(v["description"])
            if v.get("enum"):
                lines.append("# One of: " + ", ".join(v["enum"]))
            if v.get("required_when"):
                lines += wrap_comment("Required when " + v["required_when"] + ".")
            elif required_for(v, "compose"):
                lines.append("# Required.")
            default = default_for(v, "compose")
            if v.get("example") and not default:
                lines.append(f"# Example: {v['example']}")
            # Only required vars render uncommented: env_file passes empty
            # values as SET (""), and the app does not treat "" as absent —
            # a blank optional line would enable half-configured features.
            if required_for(v, "compose"):
                value = "" if v.get("secret") else (default or "")
                lines.append(f"{v['name']}={value}")
            else:
                lines.append(f"# {v['name']}={default or ''}")
            lines.append("")
        lines.pop()  # trailing blank inside category

    computed = [v for v in variables if v["source"] in ("computed", "fixed")]
    lines += [
        "",
        "## Managed for you",
        "#",
        "# The following variables are set by compose.yaml / the packaging layer",
        "# and must not be added to this file:",
    ]
    for v in computed:
        lines.append(f"#   {v['name']}")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------- values.schema.json
def json_type_for(v: dict) -> dict:
    # Env values arrive as strings in YAML but users may write bare ints/bools;
    # accept the logical type or its string form.
    if v["type"] == "integer":
        schema: dict = {
            "anyOf": [
                {"type": "integer"},
                {"type": "string", "pattern": "^-?[0-9]+$"},
            ]
        }
    elif v["type"] == "boolean":
        schema = {
            "anyOf": [
                {"type": "boolean"},
                {"type": "string", "enum": ["true", "false"]},
            ]
        }
    else:
        schema = {"type": "string"}
    if v.get("enum"):
        schema["enum"] = list(v["enum"])
    desc = " ".join(v["description"].split())
    schema["description"] = desc
    return schema


def gen_values_schema(variables: list[dict]) -> str:
    base = json.loads(SCHEMA_BASE.read_text())
    base.setdefault("$comment", GENERATED_BANNER)

    env_props: dict = {}
    env_secret_props: dict = {}
    for v in variables:
        name = v["name"]
        if v["source"] in ("computed", "fixed"):
            managed = {
                "not": {},
                "description": f"{name} is composed by the deployment packaging - never set it directly.",
            }
            env_props[name] = managed
            env_secret_props[name] = managed
            continue
        if v["category"] == "deploy":
            deploy_only = {
                "not": {},
                "description": f"{name} is a compose-only deployment setting, not read by the app.",
            }
            env_props[name] = deploy_only
            env_secret_props[name] = deploy_only
            continue
        if name in CHART_STRUCTURED_VARS:
            structured = {
                "not": {},
                "description": f"{name} has a dedicated structured chart value; do not duplicate it in env/envSecret.",
            }
            env_props[name] = structured
            env_secret_props[name] = structured
            continue
        if v["secret"]:
            env_secret_props[name] = json_type_for(v)
            # Placing a secret in the plain env map is always a mistake.
            env_props[name] = {
                "not": {},
                "description": f"{name} is a secret - set it under envSecret (or the matching structured value) instead.",
            }
        else:
            env_props[name] = json_type_for(v)
            # Routing a non-secret through the Secret is harmless and
            # occasionally wanted (values considered sensitive locally).
            env_secret_props[name] = json_type_for(v)

    props = base.setdefault("properties", {})
    # additionalProperties: false makes unknown names (typos) install-time
    # errors; variables outside the contract go through extraEnv/extraEnvFrom.
    props["env"] = {
        "type": "object",
        "description": "Extra non-secret environment variables from the app contract (rendered into the app ConfigMap). Unknown names are rejected - use extraEnv/extraEnvFrom for variables outside the contract.",
        "properties": env_props,
        "additionalProperties": False,
    }
    props["envSecret"] = {
        "type": "object",
        "description": "Extra secret environment variables from the app contract (rendered into the app Secret). Unknown names are rejected - use extraEnvFrom for secrets outside the contract.",
        "properties": env_secret_props,
        "additionalProperties": False,
    }
    return json.dumps(base, indent=2, sort_keys=False) + "\n"


# ----------------------------------------------------------------- env-vars.md
def md_escape(s: str) -> str:
    return s.replace("|", "\\|")


def gen_docs(categories: list[dict], variables: list[dict]) -> str:
    lines = [
        f"<!-- {GENERATED_BANNER} -->",
        "",
        "# Environment variable reference",
        "",
        "Variables read by the app — plus the deployment-layer settings in the",
        "final section — grouped by area. `Secret` variables belong in secret",
        "storage (`envSecret` / Kubernetes Secrets / password fields), never in",
        "plain config.",
        "",
        "Variables marked *managed* are composed by the deployment packaging",
        "(chart, compose, managed app) and should not be set by hand.",
    ]
    for cat in categories:
        cat_vars = [
            v
            for v in variables
            if v["category"] == cat["id"] and v["tier"] in ("core", "advanced")
        ]
        if not cat_vars:
            continue
        lines += ["", f"## {cat['title']}", ""]
        lines.append("| Variable | Required | Default | Secret | Description |")
        lines.append("|---|---|---|---|---|")
        for v in cat_vars:
            req = v.get("required", False)
            if isinstance(req, dict):
                req_s = ", ".join(k for k, val in sorted(req.items()) if val) or "no"
            else:
                req_s = "yes" if req else "no"
            if v.get("required_when"):
                req_s = "conditional"
            if v["source"] in ("computed", "fixed"):
                req_s = "*managed*"
            # Deploy-tier vars have no app default; fall back to the compose one.
            default = default_for(v, "app") or default_for(v, "compose") or ""
            desc = " ".join(v["description"].split())
            if v.get("notes"):
                desc += " " + " ".join(v["notes"].split())
            if v["type"] == "enum":
                desc += " One of: " + ", ".join(f"`{e}`" for e in v["enum"]) + "."
            if v.get("required_when"):
                desc += " **Required when** " + " ".join(v["required_when"].split()) + "."
            lines.append(
                f"| `{v['name']}` | {req_s} | {md_escape(default)} | "
                f"{'yes' if v['secret'] else ''} | {md_escape(desc)} |"
            )

    internal = [v for v in variables if v["tier"] == "internal"]
    lines += [
        "",
        "## Internal tuning variables",
        "",
        "Set only under guidance from EdSpace support:",
        "",
        "; ".join(f"`{v['name']}`" for v in internal),
        "",
    ]
    return "\n".join(lines)


# ------------------------------------------------------------------------ main
def main() -> int:
    check = "--check" in sys.argv[1:]
    try:
        categories, variables = load_contract()
    except ContractError as e:
        print(e, file=sys.stderr)
        return 1

    outputs = {
        OUT_ENV_EXAMPLE: gen_env_example(categories, variables),
        OUT_VALUES_SCHEMA: gen_values_schema(variables),
        OUT_DOCS: gen_docs(categories, variables),
    }

    stale = False
    for path, content in outputs.items():
        rel = path.relative_to(ROOT)
        if check:
            current = path.read_text() if path.exists() else ""
            if current != content:
                stale = True
                print(f"STALE: {rel}", file=sys.stderr)
                sys.stderr.writelines(
                    difflib.unified_diff(
                        current.splitlines(keepends=True),
                        content.splitlines(keepends=True),
                        fromfile=str(rel),
                        tofile=f"{rel} (regenerated)",
                    )
                )
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            print(f"wrote {rel}")

    if check and stale:
        print("\nRun `make gen` and commit the result.", file=sys.stderr)
        return 1
    if check:
        print("generated files are current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
