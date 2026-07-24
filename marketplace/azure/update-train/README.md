# EdSpace update train

Vendor-operated rollout of app updates across customer managed-application
instances. Customers on the managed app never run updates themselves — that's
the product promise; this pipeline is how it's kept.

## Rollout model

1. **Rings**: every instance in [`instances/instances.json`](instances/instances.json)
   carries `ring: canary | broad`. Keep at least one internal/pilot instance
   in `canary`; the rollout fails closed when that ring is empty.
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
| Infra/template change | `update-instance.sh --template` (wraps `az deployment group create` with `dist/mainTemplate.json`) | The script reads all customer-specific parameters back from the live instance (mail settings, registry user, sizing, AI/BYO config, PG sizing) and pins `bootstrapSecrets=false` — mandatory, `true` rotates every generated secret. See ../managed-app/README.md. |
| Rollback | `az containerapp update --image <previousTag>` (automatic on gate failure) | App-level only. |

**Schema policy**: migrations are forward-only. Every release must keep its
database schema backward-compatible with the previous app version, so that
image rollback after a failed health gate leaves a working instance. Breaking
schema changes require a two-release expand/contract split.

## Instance registry

`instances/instances.json` is hand-maintained for now.
`scripts/discover-instances.sh` can seed it from managed resource groups visible
to the authorized publisher identity. It only accepts the exact
`edspace.io/product=edspace` tag injected by the template; it does not infer
EdSpace from resource names. Instances created before the marker was
introduced must be added manually once.

Each entry has this shape:

```json
{
  "name": "contoso-school",
  "ring": "canary",
  "tenantId": "11111111-1111-1111-1111-111111111111",
  "subscriptionId": "22222222-2222-2222-2222-222222222222",
  "managedRg": "mrg-edspace-contoso",
  "fqdn": "edspace.example.azurecontainerapps.io"
}
```

Before GA, the marketplace **notification endpoint** (configured on the
Partner Center plan; an Azure Function writing
`{applicationId, tenantId, managedRg, plan, eventType}` to a storage table)
becomes the source of truth and discovery reads that table.

## Publisher authentication

Managed Application publisher operations execute in the **publisher tenant**.
Partner Center projects the plan's authorized publisher principal onto each
customer managed resource group. The Azure DevOps service connection principal
(or a publisher group containing it) must therefore be listed in the plan's
authorizations with the role required by the update train.

Set the pipeline's `publisherTenantId` parameter (or
`EDSPACE_PUBLISHER_TENANT_ID` for interactive runs). Scripts fail closed unless
the current Azure session belongs to that tenant, then select each projected
customer subscription without re-authenticating. Customer-tenant consent and
credentials are neither required nor used.

The permanent instance registry should still come from the Marketplace
notification endpoint, since the publisher authorization covers the managed RG
rather than the customer-owned managed-application resource.
