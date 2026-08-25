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


def main() -> None:
    elements = ui_elements()
    requirements = json.loads(REQUIREMENTS_PATH.read_text())["requirements"]
    contract_to_ui = {
        "MAILER_FROM_EMAIL": "mailFromEmail",
        "MAILPACE_API_KEY": "mailpaceApiKey",
        "MAILER_SMTP_RELAY": "mailSmtpRelay",
        "MAILER_SMTP_PASSWORD": "mailSmtpPassword",
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
        "authenticated SMTP fails before app creation when its password is blank":
            "mailerAdapter == 'smtp' && !empty(mailSmtpUsername) ? mailSmtpPassword",
        "authenticated SMTP loads the password Secret":
            "mailerAdapter == 'smtp' && !empty(mailSmtpUsername) ? keyVault.getSecret('smtp-password') : ''",
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


if __name__ == "__main__":
    main()
