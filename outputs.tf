output "function_app_name" {
  value = azurerm_function_app_flex_consumption.main.name
}

output "function_id" {
  value = local.function_id
}

output "function_identity_principal_id" {
  value = azurerm_user_assigned_identity.function.principal_id
}

output "function_identity_client_id" {
  value = azurerm_user_assigned_identity.function.client_id
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

# output "policy_assignment_id" {
#   value = azurerm_subscription_policy_assignment.kv_events.id
# }
