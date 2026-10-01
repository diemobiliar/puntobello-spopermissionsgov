
### UAMI ###
resource "azurerm_user_assigned_identity" "main" {
  name                = "pb-spopergov-${local.resource_random}-${var.environment_name}-uami"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = { azd-env-name : var.environment_name }
}

resource "azurerm_role_assignment" "userassigned_acr_pull" {
  principal_id         = azurerm_user_assigned_identity.main.principal_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}

# Sites.Selected permission
resource "azuread_app_role_assignment" "sites_selected_spo" {
  app_role_id         = "20d37865-089c-4dee-8c41-6967602d4ac8" # Sites.Selected
  principal_object_id = azurerm_user_assigned_identity.main.principal_id
  resource_object_id  = data.azuread_service_principal.spo.object_id
}

# Group.Read.All permission (to get owners of Teams)
resource "azuread_app_role_assignment" "group_read_all" {
  app_role_id         = "5b567255-7703-4780-807c-7be8301ae99b" # Group.Read.All
  principal_object_id = azurerm_user_assigned_identity.main.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Sites.FullControl.All permission (to get and set site permissions)
resource "azuread_app_role_assignment" "graph_sites_fullcontrol_all" {
  app_role_id         = "a82116e5-55eb-4c41-a434-62fe8a61c773" # Sites.FullControl.All
  principal_object_id = azurerm_user_assigned_identity.main.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Sites.FullControl.All permission (to get and set site permissions)
resource "azuread_app_role_assignment" "spo_sites_fullcontrol_all" {
  app_role_id         = "678536fe-1083-478a-9c59-b99265e6b0d3" # Sites.FullControl.All
  principal_object_id = azurerm_user_assigned_identity.main.principal_id
  resource_object_id  = data.azuread_service_principal.spo.object_id
}

# Application.Read.All permission (to get owners of App Registrations)
resource "azuread_app_role_assignment" "application_read_all" {
  app_role_id         = "9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30" # Application.Read.All
  principal_object_id = azurerm_user_assigned_identity.main.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Mail.Send permission (to send emails)
resource "azuread_app_role_assignment" "mail_send" {
  app_role_id         = "b633e1c5-b582-4048-a93e-9f11b44c7e96" # Mail.Send
  principal_object_id = azurerm_user_assigned_identity.main.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# User.Read.All permission (to get owners of App Registrations)
resource "azuread_app_role_assignment" "user_read_all" {
  app_role_id         = "df021288-bdef-4463-88db-98f22de89214" # User.Read.All
  principal_object_id = azurerm_user_assigned_identity.main.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}