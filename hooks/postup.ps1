<#
.SYNOPSIS
    azd postup hook — grants the managed identity Sites.Selected FullControl on the SharePoint site.

.DESCRIPTION
    Executed automatically by the Azure Developer CLI after infrastructure deployment.

    Reads the managed identity details and target site URL from the azd environment (written
    by Terraform outputs and the preup hook), then idempotently grants the identity
    FullControl via the Sites.Selected permission on the configured SharePoint site.

    The managed identity is the Container App Job identity provisioned by Terraform. Granting
    FullControl via Sites.Selected scopes the identity's access to this single site only,
    rather than all sites (as Sites.FullControl.All would).

.INPUTS
    azd env PB_UAMI_APP_ID      Client ID of the user-assigned managed identity (from Terraform output)
    azd env PB_UAMI_APP_NAME    Resource name of the managed identity (from Terraform output)
    azd env PB_SITE_URL         Full SharePoint site URL (set by preup.ps1)

.OUTPUTS
    None. Side effect: the managed identity holds FullControl on the configured SharePoint site.

.NOTES
    Runs in the devcontainer or inside the Docker-based azd runner.
    Requires PnP.PowerShell and the azd CLI to be available on the path.
    The check is idempotent — re-running will not duplicate the permission grant.
#>

if (Test-Path -Path "/.dockerenv") {
    $importPath = "/usr/local/bin"
} else {
    $importPath = "./.devcontainer/scripts"
}

Import-Module "$($importPath)/config.psm1" -Force -DisableNameChecking
Import-Module "$($importPath)/login.psm1" -Force -DisableNameChecking

# Read managed identity details and target site from the azd environment
$AppId   = $(azd env get-value PB_UAMI_APP_ID)
$AppName = $(azd env get-value PB_UAMI_APP_NAME)
$siteUrl = $(azd env get-value PB_SITE_URL)
$cnSite  = Connect-PnPOnline -Url $siteUrl @global:PnPCreds -ReturnConnection -WarningAction Ignore

# Check whether the identity already holds FullControl to keep the operation idempotent
$existingPermissions = Get-PnPEntraIDAppSitePermission -AppIdentity $AppId -Site $siteUrl -Connection $cnSite

if ($existingPermissions -and ($existingPermissions | ForEach-Object { $_.Roles }) -contains "FullControl") {
    Write-Information "`e[32mSites.Selected Permission for $AppId already exists.`e[0m"
} else {
    Grant-PnPEntraIDAppSitePermission -AppId $AppId -Site $siteUrl -Permissions "FullControl" -DisplayName $AppName -Connection $cnSite
    Write-Information "`e[32mGrant Sites.Selected Permission for $AppId.`e[0m"
}
