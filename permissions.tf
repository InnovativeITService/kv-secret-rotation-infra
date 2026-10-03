# Roles for the function's user-assigned identity.
# Key Vault access is not granted here: the policy deployment gives the function access to each
# vault it connects, an access policy (get, set) and a Key Vault Secrets Officer role on that vault.

data "azurerm_subscription" "current" {}

# Function host and deployment package
resource "azurerm_role_assignment" "function_host_storage" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
  principal_type       = "ServicePrincipal"
}

locals {
  key_vault_secrets_officer = "b86a8fe4-44ce-4948-aee5-eccb2c155cd7"

  # Label on the event subscriptions the policy deploys. A vault is compliant only when its
  # subscription has this label, so changing it makes remediation redeploy every vault, for
  # example to add the per-vault role to vaults connected before it existed.
  policy_template_label = "kv-secret-rotation-v2"

  # Lets the policy identity create and delete role assignments only for Key Vault Secrets
  # Officer to the function's identity (Role Based Access Control Administrator, constrained)
  policy_role_assignment_condition = <<-EOT
    (
      (
        !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
      )
      OR
      (
        @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.key_vault_secrets_officer}}
        AND
        @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {${azurerm_user_assigned_identity.function.principal_id}}
      )
    )
    AND
    (
      (
        !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
      )
      OR
      (
        @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.key_vault_secrets_officer}}
        AND
        @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {${azurerm_user_assigned_identity.function.principal_id}}
      )
    )
  EOT
}

# Built from the parts rather than looked up, because a data source only searches the
# subscription the provider is configured for
locals {
  rotation_storage_account_ids = {
    for name, account in var.rotation_storage_accounts : name => join("/", [
      "/subscriptions/${coalesce(account.subscription_id, data.azurerm_subscription.current.subscription_id)}",
      "resourceGroups/${account.resource_group_name}",
      "providers/Microsoft.Storage/storageAccounts/${name}",
    ])
  }
}

# Sign SAS tokens with the account key
resource "azurerm_role_assignment" "function_storage_key_operator" {
  for_each = var.rotation_storage_accounts

  scope                = local.rotation_storage_account_ids[each.key]
  role_definition_name = "Storage Account Key Operator Service Role"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
  principal_type       = "ServicePrincipal"
}

# Look up the resource group of an account when a secret has no storage_rg tag
resource "azurerm_role_assignment" "function_storage_reader" {
  for_each = { for name, account in var.rotation_storage_accounts : name => account if account.reader }

  scope                = local.rotation_storage_account_ids[each.key]
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
  principal_type       = "ServicePrincipal"
}
