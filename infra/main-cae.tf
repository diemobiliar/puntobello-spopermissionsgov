
### AZ CONTAINER REGISTRY ###
resource "azurerm_container_registry" "acr" {
  name                = "pbspopergov${local.resource_random}${var.environment_name}acr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = { azd-env-name : var.environment_name }
  sku                 = "Basic"
  admin_enabled       = true # required for the Terraform Docker provider to authenticate and push images
}

### CONTAINER APP ENV ###
resource "azurerm_storage_account" "cae_storage" {
  name                            = "pbspopergov${local.resource_random}${var.environment_name}st"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = { azd-env-name : var.environment_name }
}

resource "azurerm_storage_share" "share" {
  name                 = "data"
  quota                = "5"
  storage_account_name = azurerm_storage_account.cae_storage.name
}

resource "azurerm_container_app_environment" "aca_environment" {
  name                       = "pb-spopergov-${local.resource_random}-${var.environment_name}-cae"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = var.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  tags                       = { azd-env-name : var.environment_name }
  depends_on                 = [azurerm_storage_share.share, azurerm_storage_account.cae_storage]
}

resource "azurerm_container_app_environment_storage" "acae_storage" {
  name                         = "pb-spopergov-${local.resource_random}-${var.environment_name}-caest"
  container_app_environment_id = azurerm_container_app_environment.aca_environment.id
  account_name                 = azurerm_storage_account.cae_storage.name
  share_name                   = azurerm_storage_share.share.name
  access_mode                  = "ReadWrite"
  access_key                   = azurerm_storage_account.cae_storage.primary_access_key
}

### POWERSHELL SCRIPTS AND FILES ###

# Upload all files to the share root (flat). azurerm_storage_share_file's "path" argument
# (nested subfolders) is broken on azurerm provider 3.96-3.97.1 - it intermittently fails
# with "unexpected status 400 (The specifed resource name contains invalid characters.)".
# See https://github.com/hashicorp/terraform-provider-azurerm/issues/25353. Keep this flat
# and resolve mail templates via a dedicated $global:mailsPath in Invoke-Recertification.ps1
# instead of relying on a "mails" subdirectory existing in the container.
resource "azurerm_storage_share_file" "files" {
  for_each         = local.all_files
  name             = basename(each.value) # file name only
  storage_share_id = azurerm_storage_share.share.id
  source           = "${path.module}/../job/${each.value}"
  path             = null
  content_md5      = filemd5("${path.module}/../job/${each.value}")
}

### DOCKER CONTAINER ###
# Configure Docker provider to authenticate with ACR
provider "docker" {
  registry_auth {
    address  = azurerm_container_registry.acr.login_server
    username = azurerm_container_registry.acr.admin_username
    password = azurerm_container_registry.acr.admin_password
  }
}

# Build Docker image
resource "docker_image" "pbspfxtools" {
  name = "${azurerm_container_registry.acr.login_server}/pbspfxtools:latest"

  build {
    context    = "${path.module}/../.devcontainer"
    dockerfile = "Dockerfile"
    tag        = ["${azurerm_container_registry.acr.login_server}/pbspfxtools:latest"]
    build_args = {
      ARCH : "amd64"
    }
  }

  depends_on = [azurerm_container_registry.acr]
}

# Push image to ACR
resource "docker_registry_image" "pbspfxtools" {
  name = docker_image.pbspfxtools.name
}