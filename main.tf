resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_user_assigned_identity" "function" {
  name                = "${var.name_prefix}-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

# Function host storage, deployment package and dead-lettered events
resource "azurerm_storage_account" "main" {
  name                            = var.storage_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "deployment" {
  name                  = "app-package"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "deadletter" {
  name                  = "eventgrid-deadletter"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.name_prefix}-law"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "main" {
  name                = "${var.name_prefix}-ai"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "other"
  tags                = var.tags
}

resource "azurerm_service_plan" "main" {
  name                = "${var.name_prefix}-plan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "main" {
  name                = "${var.name_prefix}-func"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true

  # No publish-profile (username/password) deployments; deploy with an Entra ID sign-in
  # (func azure functionapp publish, az functionapp deployment, Terraform)
  webdeploy_publish_basic_authentication_enabled = false

  runtime_name           = "python"
  runtime_version        = var.python_version
  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.main.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.function.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.function.id]
  }

  app_settings = {
    # DefaultAzureCredential picks the user-assigned identity from this
    AZURE_CLIENT_ID       = azurerm_user_assigned_identity.function.client_id
    AZURE_SUBSCRIPTION_ID = var.subscription_id

    # Where Event Grid dead-letters undeliverable events; deadletter_check reports them
    DEADLETTER_ACCOUNT_URL = azurerm_storage_account.main.primary_blob_endpoint
    DEADLETTER_CONTAINER   = azurerm_storage_container.deadletter.name

    # Jira tickets for rotations, disabled while testing rotation; uncomment with the
    # jira_* variables in variables.tf to raise tickets again
    # JIRA_WEBHOOK_URL   = var.jira_webhook_url
    # JIRA_WEBHOOK_TOKEN = var.jira_webhook_token

    # Host storage over the identity, no account key. The provider always writes an
    # AzureWebJobsStorage connection string with an empty AccountKey, which the host
    # prefers over the identity settings; blanking it makes the host use them.
    AzureWebJobsStorage              = ""
    AzureWebJobsStorage__accountName = azurerm_storage_account.main.name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = azurerm_user_assigned_identity.function.client_id
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.main.connection_string
  }

  tags = var.tags

  depends_on = [azurerm_role_assignment.function_host_storage]
}

locals {
  function_id = "${azurerm_function_app_flex_consumption.main.id}/functions/${var.function_name}"
}
