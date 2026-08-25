# Changelog

All notable changes to the EdSpace self-deploy packaging are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver and equal the Helm chart version.

## [Unreleased]

### Added
- Initial packaging: customer Helm chart (`chart/edspace`), Docker Compose deployment, Azure Marketplace Managed Application assets, environment-variable contract (`config/contract.yaml`) with codegen.
- Azure template: `mailerAdapter` (`mailpace` / `smtp` / `none`) and Microsoft Entra ID sign-in parameters, both also in the portal form.
- `MEMBER_PURGE_ENABLED` break-glass switch in the customer contract.

### Changed
- `LANGFUSE_TIMEOUT` is now in **seconds** (integer or float), matching the app; it was documented as milliseconds. A value carried over from the old docs (e.g. `5000`) must be divided by 1000 — the chart now rejects an out-of-range value rather than accepting it as a 5000-second timeout. Accepted range: `0.1`–`120`.
- Azure template: `mailFromEmail` / `mailSmtpRelay` are no longer required parameters; the template rejects a deployment that omits them for an adapter that needs them, and an SMTP password without a username.
- Helm chart: an SMTP **password without a username** is now rejected, matching the existing rule for a username without a password and the Azure template's. The app authenticates only when `MAILER_SMTP_USERNAME` is set, so a lone password was accepted and then silently ignored. An unauthenticated relay leaves both empty; a username supplied through `extraEnv` still satisfies the rule.
- Azure template: a missing `mailpaceApiKey`, `microsoftClientId` or `microsoftClientSecret` now fails with a message naming the parameter. Previously the first and last were caught only by Key Vault rejecting an empty secret value — mid-deployment, with an ARM error naming neither the parameter nor the feature — and an empty `microsoftClientId` was not caught at all: the deployment succeeded and the app read it as "provider off", leaving the sign-in button missing.

### Removed
- `EDSPACE_SPEECH_VOICE`, `EDSPACE_SPEECH_RECOGNITION_LANGUAGE`, `EDSPACE_SPEECH_RECOGNITION_LANGUAGES` and `DEBUG_AUTH_FAILURES` left the contract: the speech settings moved to the in-app platform settings and the debug flag is not customer-facing. Because `env:`/`envSecret:` reject unknown names, `helm upgrade` fails until these keys are removed from your values. If an app version still reads one, pass it through `extraEnv` instead.

### Upgrade notes
- Azure instances installed before `smtp-password` / `microsoft-client-secret` existed in the Key Vault must seed those secrets before a `bootstrapSecrets=false` redeploy that enables SMTP authentication or Microsoft SSO — see `marketplace/azure/managed-app/README.md`, *Secret model*.
- The same applies to any Azure instance **enabling SMTP authentication or Microsoft SSO for the first time**, even where the secret already exists: it still holds the `unused-…` placeholder written at install, a `bootstrapSecrets=false` redeploy does not rewrite it, and the placeholder is then bound as though it were the real credential. There is no deployment error in this case — authentication fails at runtime. Set the secret before redeploying.
- Helm releases with `mailer.smtp.password` set but no `mailer.smtp.username` will fail `helm upgrade` until one of the two is removed. That combination never authenticated; if your relay does not require credentials, clear the password.

### App compatibility
- Validated against app image: _TBD (set on first release)_.
