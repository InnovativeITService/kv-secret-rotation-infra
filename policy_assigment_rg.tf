# DeployIfNotExists policy: every Key Vault in scope (existing or new) gets an Event Grid
# subscription to the rotation function, on the vault's existing system topic or a new one,
# plus an access policy for the function's identity. A vault counts as compliant once it
# has a subscription delivering to the function.

locals {
  # Built-in roles the policy's managed identity needs to deploy the template
  policy_roles = {
    eventgrid_contributor = "1e241071-0855-49ea-94dc-649edcd759de" # system topics and subscriptions, deployments
    keyvault_contributor  = "f25e0fa2-a7c8-4377-a976-54943a77a395" # read vaults, add access policies
    rbac_admin            = "f58310d9-a9f6-439a-9e8d-f62e7b41a168" # give the function Key Vault Secrets Officer on each vault (constrained)
  }
}

resource "azurerm_policy_definition" "kv_events" {
  name         = "${var.name_prefix}-deploy-kv-events"
  display_name = "Deploy Key Vault secret events to the rotation function"
  description  = "Creates an Event Grid system topic on each Key Vault with a subscription to the SAS rotation function, and grants the function access to the vault's secrets."
  policy_type  = "Custom"
  mode         = "Indexed"

  metadata = jsonencode({ category = "Key Vault" })

  parameters = jsonencode({
    effect                     = { type = "String", allowedValues = ["DeployIfNotExists", "AuditIfNotExists", "Disabled"], defaultValue = "DeployIfNotExists" }
    functionResourceId         = { type = "String" }
    functionPrincipalId        = { type = "String" }
    tenantId                   = { type = "String" }
    deadLetterStorageAccountId = { type = "String" }
    deadLetterContainerName    = { type = "String" }
    includedEventTypes         = { type = "Array" }
    eventSubscriptionName      = { type = "String" }
    templateVersionLabel       = { type = "String", defaultValue = "" } # default so it can be added while the policy is assigned
  })

  policy_rule = jsonencode({
    if = {
      field  = "type"
      equals = "Microsoft.KeyVault/vaults"
    }
    then = {
      effect = "[parameters('effect')]"
      details = {
        # The event subscription on the vault, whichever system topic backs it. Matching the
        # subscription rather than the topic means a topic alone does not count as compliant.
        type = "Microsoft.EventGrid/eventSubscriptions"
        name = "[parameters('eventSubscriptionName')]"
        # and carries the current template label, so a template change redeploys existing vaults.
        existenceCondition = {
          allOf = [
            {
              field  = "Microsoft.EventGrid/eventSubscriptions/destination.AzureFunction.resourceId"
              equals = "[parameters('functionResourceId')]"
            },
            {
              count = {
                field = "Microsoft.EventGrid/eventSubscriptions/labels[*]"
                where = { field = "Microsoft.EventGrid/eventSubscriptions/labels[*]", equals = "[parameters('templateVersionLabel')]" }
              }
              greater = 0
            },
          ]
        }
        roleDefinitionIds = concat(
          [for id in values(local.policy_roles) : "/providers/Microsoft.Authorization/roleDefinitions/${id}"],
          # Custom roles in roles.tf: use the function as an endpoint, use the dead-letter storage
          [azurerm_role_definition.policy_function_endpoint.role_definition_resource_id, azurerm_role_definition.policy_deadletter_writer.role_definition_resource_id],
        )
        deployment = {
          properties = {
            mode     = "incremental"
            template = jsondecode(file("${path.module}/policy/deploy-kv-events.json"))
            parameters = {
              vaultName                  = { value = "[field('name')]" }
              functionResourceId         = { value = "[parameters('functionResourceId')]" }
              functionPrincipalId        = { value = "[parameters('functionPrincipalId')]" }
              tenantId                   = { value = "[parameters('tenantId')]" }
              deadLetterStorageAccountId = { value = "[parameters('deadLetterStorageAccountId')]" }
              deadLetterContainerName    = { value = "[parameters('deadLetterContainerName')]" }
              includedEventTypes         = { value = "[parameters('includedEventTypes')]" }
              eventSubscriptionName      = { value = "[parameters('eventSubscriptionName')]" }
              templateVersionLabel       = { value = "[parameters('templateVersionLabel')]" }
            }
          }
        }
      }
    }
  })
}

data "azurerm_resource_group" "policy_scope" {
  name = "bigwx-rg-sri"
}

resource "azurerm_resource_group_policy_assignment" "kv_events" {
  name                 = "${var.name_prefix}-kv-events"
  display_name         = "Deploy Key Vault secret events to ${azurerm_function_app_flex_consumption.main.name}"
  policy_definition_id = azurerm_policy_definition.kv_events.id
  resource_group_id    = data.azurerm_resource_group.policy_scope.id
  location             = var.location

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    effect                     = { value = var.policy_effect }
    functionResourceId         = { value = local.function_id }
    functionPrincipalId        = { value = azurerm_user_assigned_identity.function.principal_id }
    tenantId                   = { value = azurerm_user_assigned_identity.function.tenant_id }
    deadLetterStorageAccountId = { value = azurerm_storage_account.main.id }
    deadLetterContainerName    = { value = azurerm_storage_container.deadletter.name }
    includedEventTypes         = { value = var.included_event_types }
    eventSubscriptionName      = { value = var.event_subscription_name }
    templateVersionLabel       = { value = local.policy_template_label }
  })
}



resource "azurerm_role_assignment" "policy_eventgrid" {
  scope              = data.azurerm_resource_group.policy_scope.id
  role_definition_id = "${data.azurerm_subscription.current.id}/providers/Microsoft.Authorization/roleDefinitions/${local.policy_roles.eventgrid_contributor}"
  principal_id       = azurerm_resource_group_policy_assignment.kv_events.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "policy_keyvault" {
  scope              = data.azurerm_resource_group.policy_scope.id
  role_definition_id = "${data.azurerm_subscription.current.id}/providers/Microsoft.Authorization/roleDefinitions/${local.policy_roles.keyvault_contributor}"
  principal_id       = azurerm_resource_group_policy_assignment.kv_events.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "policy_function" {
  scope              = azurerm_function_app_flex_consumption.main.id
  role_definition_id = azurerm_role_definition.policy_function_endpoint.role_definition_resource_id
  principal_id       = azurerm_resource_group_policy_assignment.kv_events.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

# Event Grid checks storageAccounts/write on the dead-letter account when creating the subscription
resource "azurerm_role_assignment" "policy_deadletter" {
  scope              = azurerm_storage_account.main.id
  role_definition_id = azurerm_role_definition.policy_deadletter_writer.role_definition_resource_id
  principal_id       = azurerm_resource_group_policy_assignment.kv_events.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

# Lets the deployment give the function Key Vault Secrets Officer on each RBAC-mode vault. The
# condition limits it to exactly that role for exactly that identity.
resource "azurerm_role_assignment" "policy_rbac_admin" {
  scope              = data.azurerm_resource_group.policy_scope.id
  role_definition_id = "${data.azurerm_subscription.current.id}/providers/Microsoft.Authorization/roleDefinitions/${local.policy_roles.rbac_admin}"
  principal_id       = azurerm_resource_group_policy_assignment.kv_events.identity[0].principal_id
  principal_type     = "ServicePrincipal"
  condition_version  = "2.0"
  condition          = local.policy_role_assignment_condition
}

# Brings existing vaults into line. New vaults are handled automatically by the assignment.
resource "azurerm_resource_group_policy_remediation" "kv_events" {
  count = var.create_remediation ? 1 : 0

  name                    = "${var.name_prefix}-kv-events"
  resource_group_id       = data.azurerm_resource_group.policy_scope.id
  policy_assignment_id    = azurerm_resource_group_policy_assignment.kv_events.id
  resource_discovery_mode = "ReEvaluateCompliance"

  depends_on = [
    azurerm_role_assignment.policy_eventgrid,
    azurerm_role_assignment.policy_keyvault,
    azurerm_role_assignment.policy_function,
    azurerm_role_assignment.policy_deadletter,
    azurerm_role_assignment.policy_rbac_admin,
  ]
}
