#!/usr/bin/env python3
"""Static regression checks for conditional requirements outside Helm.

Helm scenarios execute in test-chart-validation.sh. This companion check pins
the Azure portal predicates and their Bicep enforcement so a form/template edit
cannot silently drift from the structured conditions in config/contract.yaml.
The contract AST itself is validated by scripts/gen.py.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI_PATH = ROOT / "marketplace" / "azure" / "managed-app" / "createUiDefinition.json"
BICEP_PATH = ROOT / "marketplace" / "azure" / "managed-app" / "mainTemplate.bicep"
REQUIREMENTS_PATH = ROOT / "config" / "conditional-requirements.json"
CONTAINER_BICEP_PATH = (
    ROOT / "marketplace" / "azure" / "managed-app" / "modules" / "containerApp.bicep"
)
COMPILED_PATH = ROOT / "marketplace" / "azure" / "managed-app" / "azuredeploy.json"

# Guards that reject a parameter combination the portal form cannot produce but
# a CLI or parameters-file deployment can. Each must survive compilation AND be
# read by something downstream: an unreferenced fail() variable is never
# evaluated by ARM, so a guard that loses its last consumer stops guarding
# without any visible change to the template.
EXPECTED_GUARDS = {
    "mailFromEmailChecked",
    "mailSmtpRelayChecked",
    "mailSmtpUsernameChecked",
    "mailpaceApiKeyChecked",
    "microsoftClientIdChecked",
    "microsoftClientSecretChecked",
}


def ui_elements() -> dict[str, dict]:
    document = json.loads(UI_PATH.read_text())
    elements: dict[str, dict] = {}

    for step in document["parameters"]["steps"]:
        for element in step.get("elements", []):
            name = element.get("name")
            if name:
                elements[name] = element

    return elements


def assert_equal(actual: object, expected: object, label: str) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


AZURE_FIELDS = {
    "MAILER_ADAPTER": "steps('application').mailerAdapter",
    "MAILER_SMTP_USERNAME": "steps('application').mailSmtpUsername",
    "MAILER_SMTP_PASSWORD": "steps('application').mailSmtpPassword",
}


def azure_condition(condition: dict) -> str:
    if "all" in condition:
        return f"and({', '.join(azure_condition(child) for child in condition['all'])})"
    if "any" in condition:
        return f"or({', '.join(azure_condition(child) for child in condition['any'])})"

    field = AZURE_FIELDS[condition["var"]]
    if "equals" in condition:
        return f"equals({field}, '{condition['equals']}')"
    if "one_of" in condition:
        comparisons = [f"equals({field}, '{value}')" for value in condition["one_of"]]
        return f"or({', '.join(comparisons)})"
    if condition.get("present") is True:
        return f"not(empty({field}))"
    raise AssertionError(f"unsupported Azure condition: {condition!r}")


def check_parameter_guards() -> None:
    template = json.loads(COMPILED_PATH.read_text())
    variables = template.get("variables") or {}

    guards = {name for name, expr in variables.items() if "fail(" in json.dumps(expr)}
    missing = EXPECTED_GUARDS - guards
    if missing:
        raise AssertionError(f"compiled template lost fail() guards: {sorted(missing)}")
    extra = guards - EXPECTED_GUARDS
    if extra:
        raise AssertionError(
            f"undeclared fail() guards: {sorted(extra)} - add them to EXPECTED_GUARDS"
        )

    # Reachability: the guard has to appear somewhere other than its own
    # definition, or ARM never evaluates it.
    for guard in sorted(EXPECTED_GUARDS):
        consumers = json.dumps(
            {
                "resources": template.get("resources"),
                "outputs": template.get("outputs"),
                "variables": {k: v for k, v in variables.items() if k != guard},
            }
        )
        if f"variables('{guard}')" not in consumers:
            raise AssertionError(
                f"{guard} is never read, so its fail() can never fire"
            )

    print("ok - Azure parameter guards compile and stay reachable")


def main() -> None:
    elements = ui_elements()
    requirements = json.loads(REQUIREMENTS_PATH.read_text())["requirements"]
    contract_to_ui = {
        "MAILER_FROM_EMAIL": "mailFromEmail",
        "MAILPACE_API_KEY": "mailpaceApiKey",
        "MAILER_SMTP_RELAY": "mailSmtpRelay",
        "MAILER_SMTP_PASSWORD": "mailSmtpPassword",
        # Both halves of the SMTP credential pair carry a requirement, each
        # conditioned on the other, so neither can be supplied alone.
        "MAILER_SMTP_USERNAME": "mailSmtpUsername",
    }

    for variable, element_name in contract_to_ui.items():
        predicate = f"[{azure_condition(requirements[variable]['condition'])}]"
        assert_equal(
            elements[element_name]["constraints"]["required"],
            predicate,
            f"{element_name}.required",
        )

    provider_required = {
        "microsoftTenantId": "[steps('signin').enableMicrosoftSso]",
        "microsoftClientId": "[steps('signin').enableMicrosoftSso]",
        "microsoftClientSecret": "[steps('signin').enableMicrosoftSso]",
    }

    for name, predicate in provider_required.items():
        assert_equal(elements[name]["constraints"]["required"], predicate, f"{name}.required")

    bicep = BICEP_PATH.read_text() + "\n" + CONTAINER_BICEP_PATH.read_text()
    fragments = {
        # Reading the *Checked* variable is what makes the username/password
        # pairing guard reachable; against the raw parameter the vault would
        # simply take a blank value and fail with an opaque ARM BadRequest.
        "authenticated SMTP writes its password through the pairing guard":
            "mailerAdapter == 'smtp' && !empty(mailSmtpUsernameChecked) ? mailSmtpPassword",
        "authenticated SMTP binds the password Secret":
            "mailerAdapter == 'smtp' && !empty(mailSmtpUsername) ? ['smtp-password'] : []",
        "disabled Entra emits no provider configuration":
            "enableMicrosoftSso ? [\n    { name: 'MICROSOFT_TENANT_ID'",
        # A custom domain is bound after install; both origins must stay
        # allowed so the instance (WebSockets included) works at the generated
        # address during the cutover.
        "custom domain keeps the generated origin allowed during cutover":
            ": 'https://${customDomain},https://${generatedHost}'",
        "PHX_CHECK_ORIGIN is the computed origin list":
            "{ name: 'PHX_CHECK_ORIGIN', value: checkOrigin }",
        # Outputs must name the host the app itself uses, or the customer
        # registers the wrong redirect URI / opens the wrong address.
        "appUrl output uses the app host":
            "output appUrl string = 'https://${phxHost}'",
        "Microsoft redirect output uses the app host":
            "output microsoftRedirectUri string = 'https://${phxHost}/auth/microsoft/callback'",
    }

    for label, fragment in fragments.items():
        if fragment not in bicep:
            raise AssertionError(f"{label}: missing Bicep fragment {fragment!r}")

    print("ok - Azure conditional requirements match the deployment contract")
    check_parameter_guards()


if __name__ == "__main__":
    main()
