# Email alerts from the function's App Insights logs.
#
# Event Grid's own delivery metrics live on each vault's system topic, which Event Grid creates,
# so they can't be alerted on from here. An event Event Grid gives up on (dead-lettered) is
# caught by the deadletter_check function instead, which logs an error per dead-lettered event.

resource "azurerm_monitor_action_group" "alerts" {
  name                = "${var.name_prefix}-alerts"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "kvrotalerts"
  tags                = var.tags

  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

locals {
  alerts = {
    function-errors = {
      description = "The rotation function failed (unhandled error). Event Grid retries; if it keeps failing the event is dead-lettered."
      severity    = 1
      query       = <<-KQL
        union exceptions, (traces | where severityLevel >= 3)
        | where operation_Name == "kv_secret_expiry"
      KQL
    }
    dead-lettered = {
      description = "Event Grid gave up delivering a Key Vault event to the rotation function. The secret was not rotated; see the log line for the secret and reason."
      severity    = 1
      query       = <<-KQL
        traces
        | where operation_Name == "deadletter_check" and severityLevel >= 3
      KQL
    }
    manual-rotation = {
      description = "A secret could not be rotated automatically and needs a person (the log line gives the secret and reason)."
      severity    = 2
      query       = <<-KQL
        traces
        | where operation_Name == "kv_secret_expiry" and message startswith "Cannot rotate"
      KQL
    }
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "alerts" {
  for_each = local.alerts

  name                 = "${var.name_prefix}-${each.key}"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  description          = each.value.description
  severity             = each.value.severity
  scopes               = [azurerm_application_insights.main.id]
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  tags                 = var.tags

  criteria {
    query                   = each.value.query
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.alerts.id]
  }
}
