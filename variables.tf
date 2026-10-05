variable "subscription_id" {
  type        = string
  description = "Subscription to deploy into. The policy is assigned at this subscription."
}

variable "location" {
  type        = string
  description = "Region for all resources."
  default     = "australiaeast"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group created for the rotation resources."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names, e.g. kvrot-sri."
}

variable "storage_account_name" {
  type        = string
  description = "Storage account for the function host, deployment package and dead letters. 3-24 lowercase letters and digits, globally unique."

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase letters and digits."
  }
}

variable "python_version" {
  type        = string
  description = "Python version for the function app."
  default     = "3.14"
}

variable "function_name" {
  type        = string
  description = "Name of the function inside the app that handles Key Vault events."
  default     = "kv_secret_expiry"
}

variable "included_event_types" {
  type        = list(string)
  description = "Key Vault event types delivered to the function."
  default = [
    "Microsoft.KeyVault.SecretNearExpiry",
    "Microsoft.KeyVault.SecretExpired",
  ]
}

variable "event_subscription_name" {
  type        = string
  description = "Name of the event subscription the policy creates on each Key Vault system topic."
  default     = "kv-secret-rotation"
}

variable "rotation_storage_accounts" {
  type = map(object({
    resource_group_name = string
    subscription_id     = optional(string)
  }))
  description = <<-EOT
    Extra storage accounts the function issues SAS tokens for, keyed by account name, that are
    outside the policy's scope. Accounts in the policy's resource group or subscriptions are
    covered automatically. subscription_id defaults to the subscription deployed into.
  EOT
  default     = {}
}

variable "alert_email" {
  type        = string
  description = "Email address the alerts in alerts.tf are sent to."
}

variable "policy_effect" {
  type        = string
  description = "Effect of the Key Vault events policy."
  default     = "DeployIfNotExists"

  validation {
    condition     = contains(["DeployIfNotExists", "AuditIfNotExists", "Disabled"], var.policy_effect)
    error_message = "policy_effect must be DeployIfNotExists, AuditIfNotExists or Disabled."
  }
}

variable "policy_not_scopes" {
  type        = list(string)
  description = "Resource group or resource IDs excluded from the policy."
  default     = []
}

variable "policy_subscription_ids" {
  type        = list(string)
  description = "Subscription IDs (GUIDs) to assign the Key Vault events policy to (policy_assignment_sub.tf). Empty creates nothing."
  default     = []

  validation {
    condition     = alltrue([for id in var.policy_subscription_ids : can(regex("^[0-9a-fA-F-]{36}$", id))])
    error_message = "policy_subscription_ids must be subscription GUIDs, not /subscriptions/... IDs."
  }
}

variable "policy_definition_management_group_id" {
  type        = string
  description = "Management group to keep the subscription-scope policy definition in, e.g. /providers/Microsoft.Management/managementGroups/<name>. Required when policy_subscription_ids includes subscriptions other than the one deployed into."
  default     = null
}

variable "create_remediation" {
  type        = bool
  description = "Create a remediation task so existing vaults get the events. Turn on only after the function code is deployed, because Event Grid rejects a subscription to a function that does not exist."
  default     = false
}

# variable "jira_webhook_url" {
#   type        = string
#   description = "Jira automation incoming webhook URL, called for secrets the function can't rotate."
#   sensitive   = true
# }

# variable "jira_webhook_token" {
#   type        = string
#   description = "Value for the webhook's X-Automation-Webhook-Token header, if the webhook uses one."
#   sensitive   = true
#   default     = ""
# }

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource."
  default = {
    environment = "dev"
    project     = "kv-secret-rotation"
    owner       = "team-name"
    CostCentre  = "team-name"
    application = "kv-secret-rotation"
    ManagedBy   = "team-name"
    Support     = "team-name"
  }
}
