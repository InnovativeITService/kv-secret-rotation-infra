# kv-secret-rotation-infra

Infrastructure for the Key Vault secret rotation function (`../kv-secret-rotation`).

## What it creates

| File | Resources |
|---|---|
| `main.tf` | Resource group, user-assigned identity, storage account (host, `app-package`, `eventgrid-deadletter`), Log Analytics, App Insights, Flex Consumption plan and function app |
| `permissions.tf` | Roles for the function's identity |
| `policy_assigment_rg.tf` | Policy definition, assignment to one resource group (`bigwx-rg-sri`), roles for the policy identity, optional remediation. **This is the one in use.** |
| `policy_assignment_sub.tf` | The same policy assigned to each subscription in `policy_subscription_ids` (empty by default, so it creates nothing), with the policy roles and remediation per subscription. Subscriptions other than the deployment one need `policy_definition_management_group_id`, because a definition kept in a subscription can only be assigned there. Don't cover the same vaults with both files. |
| `policy/deploy-kv-events.json` | ARM template the policy deploys for each Key Vault |

The function app uses a **user-assigned identity** for everything: host storage, deployment
package, Key Vault and storage key access. `AZURE_CLIENT_ID` tells `DefaultAzureCredential` which
identity to use.

## Permissions

Function identity:

| Role | Scope | Why |
|---|---|---|
| Storage Blob Data Owner | function storage account | Host storage and deployment package |
| Key Vault Secrets Officer | each vault the policy connects, added by the policy | Read and write secrets in RBAC-mode vaults |
| Access policy `get`, `set` on secrets | each vault the policy connects, added by the policy | Same, for access-policy vaults |
| Storage Account Key Operator Service Role | each account in `rotation_storage_accounts` | List keys to sign SAS |

The function has no Key Vault access of its own: it can only reach vaults the policy has
connected, which are the only vaults that send it events. Each vault gets both the role and the
access policy; the vault uses whichever matches its access model and ignores the other.
| Reader | same, unless `reader = false` | Look up the resource group when a secret has no `storage_rg` tag |

Policy assignment identity:

| Role | Scope | Why |
|---|---|---|
| EventGrid Contributor | policy scope (`bigwx-rg-sri`) | Create event subscriptions, run deployments |
| Key Vault Contributor | policy scope | Read vaults, add the access policy |
| Website Contributor | function app | Use the function as an Event Grid endpoint |
| Storage Account Contributor | function storage account | Event Grid checks `storageAccounts/write` on the dead-letter account when creating a subscription |
| Role Based Access Control Administrator, **constrained** | policy scope | Give the function Key Vault Secrets Officer on each vault. A condition limits it to assigning (or removing) exactly that role, to exactly the function's identity |

Whoever runs `terraform apply` needs Owner or User Access Administrator on the subscription to
create these role assignments and the policy.

## The policy

`DeployIfNotExists` on `Microsoft.KeyVault/vaults`. A vault is compliant when it has an
Event Grid subscription named `kv-secret-rotation` whose destination is the function. For a
non-compliant vault it deploys:

1. Event subscription `kv-secret-rotation` on the vault, for `SecretNearExpiry` and
   `SecretExpired`, with the retry policy and dead-lettering to `eventgrid-deadletter`.
   Created on the vault rather than on a named topic, so Event Grid attaches it to the vault's
   existing system topic whatever it is called, or creates one if there is none.
2. Access policy for the function identity (`get`, `set` on secrets), for access-policy vaults.
3. Key Vault Secrets Officer on the vault for the function identity, for RBAC-mode vaults.

The check is on the subscription, not the topic, so a topic left behind by a failed deployment
does not make a vault look compliant.

The subscription also carries a label (`policy_template_label` in `permissions.tf`, currently
`kv-secret-rotation-v2`), and the check requires it. After changing the template, change the
label and run the remediation again: every vault then counts as non-compliant and is redeployed
with the new template, instead of keeping what the old one deployed.

New vaults are handled automatically shortly after they are created. Existing vaults need a
remediation task (`create_remediation = true`). A remediation runs once; to run it again, for
example after a fix, replace it:

```bash
terraform apply -replace='azurerm_resource_group_policy_remediation.kv_events[0]'
```

## Deploy

The order matters: Event Grid rejects a subscription to a function that has no code yet.

```bash
# 1. Infrastructure, policy without remediation
terraform init
terraform apply

# 2. Function code
cd ../kv-secret-rotation
func azure functionapp publish $(terraform -chdir=../kv-secret-rotation-infra output -raw function_app_name)

# 3. Remediate existing vaults
cd ../kv-secret-rotation-infra
terraform apply -var create_remediation=true
```

Set `create_remediation = true` in `terraform.tfvars` afterwards so the next apply keeps it.

Check what the policy found, and any failed remediation deployments:

```bash
az policy state list -g bigwx-rg-sri \
  --filter "policyAssignmentName eq 'kvrot-sri-kv-events'" \
  --query "[].{vault:resourceId, state:complianceState}" -o table
az policy remediation deployment list -g bigwx-rg-sri -n kvrot-sri-kv-events -o table
```

## Notes

- **`AzureWebJobsStorage = ""` in `app_settings`** works around an azurerm provider bug
  (open as of 5.8.0: issues #29693, #33211; fix in PR #29910). With identity-based storage the
  provider still writes an `AzureWebJobsStorage` connection string with an empty `AccountKey`,
  which the host prefers over the identity settings, so storage rejects every request. Blanking
  it makes the host use the `AzureWebJobsStorage__*` identity settings. Every `plan` shows
  `+ AzureWebJobsStorage = ""`; that's expected. Don't add `ignore_changes` for it, or the next
  update writes the broken string back. Remove the line once the provider is fixed.
- **`https_only = true`** is required by the `Secure-Cloud-Guardrails-Cyber` policy ("Function
  apps should only be accessible over HTTPS"); without it, creating the app is denied.
- **Jira:** the `JIRA_WEBHOOK_URL` / `JIRA_WEBHOOK_TOKEN` app settings and the `jira_*`
  variables are commented out while Jira is disabled in the function. When turning them on, pass
  the URL with `TF_VAR_jira_webhook_url` rather than `terraform.tfvars`; it is stored in plain
  text in state and app settings either way.
- Dead-lettering uses the storage account directly (no identity), so the account keeps shared
  key access and public network access enabled.
- Add every storage account the function issues SAS tokens for to `rotation_storage_accounts`.
  For an account in another subscription, set its `subscription_id`.
- State is local. Add a `backend` block to `versions.tf` before sharing.
