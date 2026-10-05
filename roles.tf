# Custom roles with only the actions needed, in place of broader built-in roles.

# Function identity, on the policy's scope (every storage account in it) and on any extra
# accounts in rotation_storage_accounts. Replaces Storage Account Key Operator Service Role
# (which can also regenerate keys) and Reader.
resource "azurerm_role_definition" "function_sas_signer" {
  name        = "${var.name_prefix} SAS signer"
  scope       = data.azurerm_subscription.current.id
  description = "Read a storage account and list its keys, to sign SAS tokens. Cannot regenerate keys or change the account."

  permissions {
    actions = [
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/listkeys/action",
    ]
  }

  assignable_scopes = distinct(concat(
    [data.azurerm_subscription.current.id],
    [for id in var.policy_subscription_ids : "/subscriptions/${id}"],
    [for account in var.rotation_storage_accounts : "/subscriptions/${coalesce(account.subscription_id, data.azurerm_subscription.current.subscription_id)}"],
  ))
}

# Policy identity, on the function app. Event Grid needs this to use the function as an
# endpoint (it reads the app, fetches the Event Grid system key, and checks functions/write).
# Replaces Website Contributor, which could also deploy code to the function.
resource "azurerm_role_definition" "policy_function_endpoint" {
  name        = "${var.name_prefix} Event Grid function endpoint"
  scope       = data.azurerm_subscription.current.id
  description = "Read a function app and its keys so Event Grid can deliver to it. Cannot change the app or deploy code."

  permissions {
    actions = [
      "Microsoft.Web/sites/read",
      "Microsoft.Web/sites/functions/read",
      "Microsoft.Web/sites/host/listkeys/action",
      "Microsoft.Web/sites/functions/listkeys/action",
      # Event Grid checks this on the function when a subscription is created (linked access check).
      # It covers a function's settings, not the app's code package.
      "Microsoft.Web/sites/functions/write",
    ]
  }

  assignable_scopes = [azurerm_resource_group.main.id]
}

# Policy identity, on the dead-letter storage account. Event Grid checks storageAccounts/write
# on the dead-letter account when a subscription is created. Replaces Storage Account
# Contributor, which could also list the keys and so modify the function's deployment package.
resource "azurerm_role_definition" "policy_deadletter_writer" {
  name        = "${var.name_prefix} Event Grid dead-letter destination"
  scope       = data.azurerm_subscription.current.id
  description = "The storage account permissions Event Grid checks for a dead-letter destination. Cannot list keys or read data."

  permissions {
    actions = [
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/write",
    ]
  }

  assignable_scopes = [azurerm_resource_group.main.id]
}
