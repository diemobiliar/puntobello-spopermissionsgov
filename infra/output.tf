output "PB_UAMI_APP_ID" {
  value       = azurerm_user_assigned_identity.main.client_id
  description = "Client ID of the user-assigned managed identity — used by the post-provision script to grant SharePoint site permissions"
}

output "PB_UAMI_APP_NAME" {
  value       = azurerm_user_assigned_identity.main.name
  description = "Resource name of the user-assigned managed identity"
}