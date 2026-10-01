locals {
  tags            = { azd-env-name : var.environment_name }
  resource_random = random_string.resource_random.result
  all_files       = fileset("${path.module}/../job", "**") # includes mails/, uploaded flat (see main-cae.tf)
}

# Random suffix to keep globally unique resource names (ACR, storage account) unique
resource "random_string" "resource_random" {
  length  = 4
  special = false
  upper   = false
  # Set to true for numbers only: numeric = true, lower = false
}

### RG ###
# Deploy resource group
resource "azurerm_resource_group" "rg" {
  name     = "pb-spopergov-${local.resource_random}-${var.environment_name}-rg"
  location = var.location
  // Tag the resource group with the azd environment name
  // This should also be applied to all resources created in this module
  tags = { azd-env-name : var.environment_name }
}

### LOG ANALYTICS ###
resource "azurerm_log_analytics_workspace" "law" {
  name                = "pb-spopergov-${local.resource_random}-${var.environment_name}-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}