# EdSpace update train

Vendor-operated rollout of app updates across customer managed-application
instances. Customers on the managed app never run updates themselves — that's
the product promise; this pipeline is how it's kept.

## Rollout model

1. **Rings**: every instance in [`instances/instances.json`](instances/instances.json)
   carries `ring: canary | broad`. Keep at least one internal/pilot instance
   in `canary`.
2. **Trigger**: manual pipeline run with `imageTag` + `expectedGitSha`
   (from the app build that produced the tag).
3. **Canary stage** updates ring 0 and health-gates each instance
   (poll `/health` for 200 with a 10-minute budget, then assert `/version`
   contains the expected sha). Any failure rolls that instance back to its
   previous image and halts the ring.
4. **Broad stage** runs after an Azure DevOps Environment approval
   (`edspace-updatetrain-broad` — configure the approval in the ADO portal).

## Update mechanics

| Kind | Command | Notes |
|---|---|---|
| Routine app update | `az containerapp update --image <tag>` | Atomic revision swap; cannot touch secrets; no parameters needed. |
| Infra/template change | `az deployment group create` with `dist/mainTemplate.json` `-p bootstrapSecrets=false` | `false` is mandatory — `true` rotates every generated secret. See ../managed-app/README.md. |
| Rollback | `az containerapp update --image <previousTag>` (automatic on gate failure) | App-level only. |

**Schema policy**: migrations are forward-only. Every release must keep its
database schema backward-compatible with the previous app version, so that
image rollback after a failed health gate leaves a working instance. Breaking
schema changes require a two-release expand/contract split.

## Instance registry

`instances/instances.json` is hand-maintained for now.
`scripts/discover-instances.sh` can seed it from tenants CI can reach.
Before GA, the marketplace **notification endpoint** (configured on the
Partner Center plan; an Azure Function writing
`{applicationId, tenantId, managedRg, plan, eventType}` to a storage table)
becomes the source of truth and discovery reads that table.

## Cross-tenant auth — open spike (TODO(edspace))

The managed-app authorization grants the publisher principal Owner on each
managed RG, but CI still needs a **token from the customer's tenant**:

- **(a) Multi-tenant app registration** consented per customer at onboarding —
  assumed by the scripts (`az login --service-principal --tenant <customer>`);
  cleanest at fleet scale.
- **(b) Azure Lighthouse** delegation — heavier onboarding, richer RBAC story.
- **(c) Interactive operator runs** — fine for the first handful of customers.

Decide before onboarding customer #2; the scripts isolate the login step so
only one block changes.
