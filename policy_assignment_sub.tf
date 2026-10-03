# DeployIfNotExists policy assigned to whole subscriptions: every Key Vault in each subscription
# in policy_subscription_ids (existing or new) gets an Event Grid subscription to the rotation
# function, on the vault's existing system topic or a new one, plus an access policy for the
# function's identity. A vault counts as compliant once it has a subscription delivering to the
# function.
#
# Same policy as policy_assigment_rg.tf, at subscription scope. Resource names differ so both
# files can be present; with policy_subscription_ids empty (the default) this file creates
# nothing. Don't assign both to the same vaults.
#
# A policy definition kept in a subscription can only be assigned in that subscription. To
# assign to other subscriptions, set policy_definition_management_group_id to a management
# group above all of them.

locals {
  sub_policy_enabled = length(var.policy_subscription_ids) > 0

  # Built-in roles the policy's managed identity needs to deploy the template
  sub_policy_roles = {
    eventgrid_contributor = "1e241071-0855-49ea-94dc-649edcd759de" # event subscriptions, deployments
    keyvault_contributor  = "f25e0fa2-a7c8-4377-a976-54943a77a395" # read vaults, add access policies
    website_contributor   = "de139f84-1756-47ae-9be6-808fbbe84772" # use the function as an Event Grid endpoint
    storage_contributor   = "17d1049b-9a84-46fb-8f53-869881c3d3ab" # use the storage account as the dead-letter destination
    rbac_admin            = "f58310d9-a9f6-439a-9e8d-f62e7b41a168" # give the function Key Vault Secrets Officer on each vault (constrained)
  }

  # Subscription ID => full resource ID
  policy_subscriptions = { for id in var.policy_subscription_ids : id => "/subscriptions/${id}" }

  # Subscriptions other than the one this configuration deploys into
  other_policy_subscriptions = {
    for id, scope in local.policy_subscriptions : id => scope
    if lower(id) != lower(data.azurerm_subscription.current.subscription_id)
  }
}

resource "azurerm_policy_definition" "kv_events_sub" {
  count = local.sub_policy_enabled ? 1 : 0

  name                = "${var.name_prefix}-deploy-kv-events-sub"
  display_name        = "Deploy Key Vault secret events to the rotation function"
  description         = "Creates an Event Grid subscription to the secret rotation function on each Key Vault, and grants the function access to the vault's secrets."
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = var.policy_definition_management_group_id

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
        roleDefinitionIds = [for id in values(local.sub_policy_roles) : "/providers/Microsoft.Authorization/roleDefinitions/${id}"]
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

resource "azurerm_subscription_policy_assignment" "kv_events" {
  for_each = local.policy_subscriptions

  name                 = "${var.name_prefix}-kv-events"
  display_name         = "Deploy Key Vault secret events to ${azurerm_function_app_flex_consumption.main.name}"
  policy_definition_id = azurerm_policy_definition.kv_events_sub[0].id
  subscription_id      = each.value
  location             = var.location
  # Exclusions must sit inside the assignment's subscription
  not_scopes = [for s in var.policy_not_scopes : s if startswith(lower(s), lower("${each.value}/"))]

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

  lifecycle {
    precondition {
      condition     = var.policy_definition_management_group_id != null || length(local.other_policy_subscriptions) == 0
      error_message = "Assigning the policy to subscriptions other than ${data.azurerm_subscription.current.subscription_id} needs policy_definition_management_group_id: a definition kept in a subscription can only be assigned there."
    }
  }
}

resource "azurerm_role_assignment" "sub_policy_eventgrid" {
  for_each = local.policy_subscriptions

  scope              = each.value
  role_definition_id = "${each.value}/providers/Microsoft.Authorization/roleDefinitions/${local.sub_policy_roles.eventgrid_contributor}"
  principal_id       = azurerm_subscription_policy_assignment.kv_events[each.key].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "sub_policy_keyvault" {
  for_each = local.policy_subscriptions

  scope              = each.value
  role_definition_id = "${each.value}/providers/Microsoft.Authorization/roleDefinitions/${local.sub_policy_roles.keyvault_contributor}"
  principal_id       = azurerm_subscription_policy_assignment.kv_events[each.key].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "sub_policy_function" {
  for_each = local.policy_subscriptions

  scope              = azurerm_function_app_flex_consumption.main.id
  role_definition_id = "${data.azurerm_subscription.current.id}/providers/Microsoft.Authorization/roleDefinitions/${local.sub_policy_roles.website_contributor}"
  principal_id       = azurerm_subscription_policy_assignment.kv_events[each.key].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

# Event Grid checks storageAccounts/write on the dead-letter account when creating the subscription
resource "azurerm_role_assignment" "sub_policy_deadletter" {
  for_each = local.policy_subscriptions

  scope              = azurerm_storage_account.main.id
  role_definition_id = "${data.azurerm_subscription.current.id}/providers/Microsoft.Authorization/roleDefinitions/${local.sub_policy_roles.storage_contributor}"
  principal_id       = azurerm_subscription_policy_assignment.kv_events[each.key].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

# Lets the deployment give the function Key Vault Secrets Officer on each RBAC-mode vault. The
# condition limits it to exactly that role for exactly that identity.
resource "azurerm_role_assignment" "sub_policy_rbac_admin" {
  for_each = local.policy_subscriptions

  scope              = each.value
  role_definition_id = "${each.value}/providers/Microsoft.Authorization/roleDefinitions/${local.sub_policy_roles.rbac_admin}"
  principal_id       = azurerm_subscription_policy_assignment.kv_events[each.key].identity[0].principal_id
  principal_type     = "ServicePrincipal"
  condition_version  = "2.0"
  condition          = local.policy_role_assignment_condition
}

# Brings existing vaults into line. New vaults are handled automatically by the assignment.
resource "azurerm_subscription_policy_remediation" "kv_events" {
  for_each = var.create_remediation ? local.policy_subscriptions : {}

  name                    = "${var.name_prefix}-kv-events"
  subscription_id         = each.value
  policy_assignment_id    = azurerm_subscription_policy_assignment.kv_events[each.key].id
  resource_discovery_mode = "ReEvaluateCompliance"

  depends_on = [
    azurerm_role_assignment.sub_policy_eventgrid,
    azurerm_role_assignment.sub_policy_keyvault,
    azurerm_role_assignment.sub_policy_function,
    azurerm_role_assignment.sub_policy_deadletter,
    azurerm_role_assignment.sub_policy_rbac_admin,
  ]
}
