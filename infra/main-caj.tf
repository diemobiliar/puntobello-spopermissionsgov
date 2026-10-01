### CONTAINER APP JOB ###
locals {
  static_env_vars = [
    {
      name  = "STAGE"
      value = var.environment_name
    },
    {
      name  = "AZURE_CLIENT_ID"
      value = azurerm_user_assigned_identity.main.client_id
    },
    {
      name  = "AZURE_SUBSCRIPTION_ID"
      value = data.azurerm_client_config.current.subscription_id
    },
    {
      name  = "AZURE_TENANT_ID"
      value = data.azurerm_client_config.current.tenant_id
    },
    {
      name  = "SITE_URL"
      value = var.site_url
    },
    {
      name  = "SENDER_MAIL"
      value = var.sender_mail
    },
    {
      name  = "TENANT_NAME"
      value = var.tenant_name
    },
    {
      name  = "TERM"
      value = "dumb"
    },
    {
      name  = "NO_COLOR"
      value = "1"
    },
    {
      name  = "INFORMATION"
      value = "1"
    },
    {
      name  = "DEBUG"
      value = "0"
    },
    {
      name  = "VERBOSE"
      value = "1"
    }
  ]
}

# App role and AcrPull assignments of the managed identity take a few minutes to propagate
# in Entra ID; wait before creating the job so its first run doesn't fail on missing permissions.
resource "time_sleep" "wait_for_identity" {
  create_duration = "180s"

  depends_on = [
    docker_registry_image.pbspfxtools,
    azurerm_role_assignment.userassigned_acr_pull,
    azuread_app_role_assignment.sites_selected_spo,
    azuread_app_role_assignment.group_read_all,
    azuread_app_role_assignment.graph_sites_fullcontrol_all,
    azuread_app_role_assignment.spo_sites_fullcontrol_all,
    azuread_app_role_assignment.application_read_all,
    azuread_app_role_assignment.mail_send,
    azuread_app_role_assignment.user_read_all,
  ]
}

resource "azapi_resource" "caj" {
  type      = "Microsoft.App/jobs@2023-05-01"
  name      = "pb-spopergov-${local.resource_random}-${var.environment_name}-caj"
  location  = var.location
  parent_id = azurerm_resource_group.rg.id
  tags      = { azd-env-name : var.environment_name }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.main.id]
  }
  body = ({
    properties = {
      environmentId = azurerm_container_app_environment.aca_environment.id
      configuration = {
        manualTriggerConfig = {
          parallelism            = 1
          replicaCompletionCount = 1
        }
        scheduleTriggerConfig = {
          cronExpression         = "0 18 * * 1-5" # 18:00 UTC, weekdays (Mon–Fri)
          parallelism            = 1
          replicaCompletionCount = 1
        }
        registries = [
          {
            server   = azurerm_container_registry.acr.login_server
            identity = azurerm_user_assigned_identity.main.id
          }
        ]
        replicaRetryLimit = 3
        replicaTimeout    = 3600
        triggerType       = "Schedule"
      }
      template = {
        containers = [
          {
            command = ["pwsh", "-File", "/mnt/scripts/Invoke-Recertification.ps1"]
            env     = local.static_env_vars
            image   = "${azurerm_container_registry.acr.login_server}/pbspfxtools:latest"
            name    = "pbspfxtools"
            resources = {
              cpu    = 1
              memory = "2Gi"
            }
            volumeMounts = [
              {
                mountPath  = "/mnt/scripts"
                volumeName = azurerm_storage_share.share.name
              }
            ]
          }
        ]
        volumes = [
          {
            name         = azurerm_storage_share.share.name
            storageName  = azurerm_container_app_environment_storage.acae_storage.name
            storageType  = "AzureFile"
            mountOptions = "dir_mode=0777,file_mode=0777,uid=1000,gid=1000,mfsymlinks,nobrl,cache=none"
          }
        ]
      }
    }
  })

  depends_on = [time_sleep.wait_for_identity]
}