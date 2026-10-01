# Input variables for the module

variable "location" {
  description = "The supported Azure location where the resource deployed"
  type        = string
}

variable "environment_name" {
  description = "The name of the azd environment to be deployed"
  type        = string
}

variable "site_url" {
  description = "Full URL of the SharePoint site to govern, e.g. https://yourtenant.sharepoint.com/sites/yoursite"
  type        = string
}

variable "sender_mail" {
  description = "Mailbox the job sends notifications from and the governance mailbox receiving unmanaged-app alerts, e.g. spogov@contoso.com"
  type        = string
}

variable "tenant_name" {
  description = "SharePoint/Entra tenant name (without .onmicrosoft.com), e.g. contoso"
  type        = string
}