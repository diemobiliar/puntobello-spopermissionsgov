<#
.SYNOPSIS
    azd preup hook — provisions the SharePoint site/lists and applies post-provisioning configuration.

.DESCRIPTION
    Executed automatically by the Azure Developer CLI before infrastructure deployment.

    Step 1 — dot-sources Deploy-SitesAndLists.ps1, which provisions the SharePoint site and
             all required lists from the spo/ templates. That script sets the global variables
             $global:M365_TENANTNAME and $global:PnPCreds used throughout this hook.

    Step 2 — reads solutions.json and applies the following site configuration:
      - Hides the spo_RequestStatus and Title fields from the new/edit forms of the Requests
        list (the status is managed by the governance job, Title is not used).
      - Shows the target resource fields in the forms only for the scopes that need them.
      - Grants the SPOPermissionsGovUsers group (created by Site.xml) Read on Home.aspx only
        (item-level permission break).
      - Removes the default Visitors group from the My Recertification list so that access
        is granted per item by the governance job rather than inherited.
      - Persists PB_SITE_URL and PB_TENANT_NAME in the azd environment for use by the
        infrastructure deployment and the postup hook.

.INPUTS
    ./spo/solutions.json        Site configuration (site relative URL, list definitions)
    $global:M365_TENANTNAME     Set by Deploy-SitesAndLists.ps1
    $global:PnPCreds            PnP credential splat set by Deploy-SitesAndLists.ps1

.OUTPUTS
    azd env PB_SITE_URL         Full SharePoint site URL, consumed by Terraform and postup.ps1
    azd env PB_TENANT_NAME      Tenant name, consumed by Terraform

.NOTES
    Runs in the devcontainer or inside the Docker-based azd runner.
    Requires PnP.PowerShell and the azd CLI to be available on the path.
#>

if (Test-Path -Path "/.dockerenv") {
    $importPath = "/usr/local/bin"
} else {
    $importPath = "./.devcontainer/scripts"
}

# Provision the SharePoint site and lists; also sets $global:M365_TENANTNAME and $global:PnPCreds
. "$importPath/Deploy-SitesAndLists.ps1"

# Ensure the target site collection configured in solutions.json exists, create if required.
if (Test-Path './spo/solutions.json') {
    Write-Information "`e[34mConfig site`e[0m"
    foreach ($site in (Get-Content ./spo/solutions.json | ConvertFrom-Json).sites) {
        $siteUrl = "https://$($global:M365_TENANTNAME).sharepoint.com/sites/$($site.Url)"
        $cnSite = Connect-PnPOnline -Url $siteUrl @global:PnPCreds -ReturnConnection -WarningAction Ignore

        # Persist site context for Terraform variables and the postup hook
        azd env set PB_SITE_URL $siteUrl
        azd env set PB_TENANT_NAME $global:M365_TENANTNAME

        ### Hide governance fields from new/edit forms in the Requests list
        # spo_RequestStatus is set by the job, not by users
        $listName   = "Requests"
        $showInForm = $false

        $fieldInternalName = "spo_RequestStatus"
        Write-Information "`e[34mHide field '$fieldInternalName' in forms`e[0m"
        $field = Get-PnPField -List $listName -Identity $fieldInternalName -Connection $cnSite
        $field.SetShowInNewForm($showInForm)
        Invoke-PnPQuery -Connection $cnSite
        $field.SetShowInEditForm($showInForm)
        Invoke-PnPQuery -Connection $cnSite

        ### Hide Title from the Requests forms, it isn't used by the process
        # Title is required on the Item content type, so it's made optional on the list field
        # and on the list content type's field link, otherwise the form can't be saved.
        Write-Information "`e[34mHide field 'Title' in forms`e[0m"
        $titleField = Get-PnPField -List $listName -Identity "Title" -Connection $cnSite
        $titleField.Required = $false
        $titleField.SetShowInNewForm($showInForm)
        $titleField.SetShowInEditForm($showInForm)
        $titleField.Update()
        Invoke-PnPQuery -Connection $cnSite
        $itemContentType = Get-PnPContentType -List $listName -Identity "Item" -Connection $cnSite
        $titleFieldLink = $itemContentType.FieldLinks.GetById($titleField.Id)
        $titleFieldLink.Required = $false
        $titleFieldLink.Hidden = $true
        $itemContentType.Update($false)
        Invoke-PnPQuery -Connection $cnSite

        ### Show target resource fields in forms only for the scopes that need them
        # The conditional formula is stored in ClientValidationFormula ('true' shows the field).
        # CustomFormatter is cleared because an earlier template stored an invalid formatter there,
        # which rendered the column values empty in list views.
        $targetResourceFormulas = @{
            spo_TargetResourceName = '=if([$spo_PermissionScope] == ''Lists.SelectedOperations.Selected'' || [$spo_PermissionScope] == ''ListItems.SelectedOperations.Selected'' || [$spo_PermissionScope] == ''Files.SelectedOperations.Selected'', ''true'', ''false'')'
            spo_TargetResourceId   = '=if([$spo_PermissionScope] == ''ListItems.SelectedOperations.Selected'' || [$spo_PermissionScope] == ''Files.SelectedOperations.Selected'', ''true'', ''false'')'
        }
        foreach ($formList in @("Requests", "My Recertification")) {
            foreach ($fieldInternalName in $targetResourceFormulas.Keys) {
                Write-Information "`e[34mSet conditional formula for field '$fieldInternalName' in '$formList'`e[0m"
                Set-PnPField -List $formList -Identity $fieldInternalName -Values @{
                    ClientValidationFormula = $targetResourceFormulas[$fieldInternalName]
                    CustomFormatter         = ""
                } -Connection $cnSite
            }
        }

        ### Grant SPOPermissionsGovUsers Read on Home.aspx only (item-level permission break)
        # The group itself is created by the provisioning template (Site.xml SiteGroups).
        # The Requests list permission (Add Items) is also set by the template.
        $groupName = "SPOPermissionsGovUsers"
        $listName  = "SitePages"
        $pageTitle = "Home.aspx"

        $pageItem = Get-PnPListItem -List $listName -Query "<View><Query><Where><Eq><FieldRef Name='FileLeafRef'/><Value Type='Text'>$pageTitle</Value></Eq></Where></Query></View>" -Connection $cnSite

        if ($pageItem) {
            Set-PnPListItemPermission -List $listName -Identity $pageItem.Id -Group $groupName -AddRole "Read" -Connection $cnSite
            Write-Information "`e[32mSuccess: Group '$groupName' has Read on Home.aspx only.`e[0m"
        }
        else {
            Write-Error "Home.aspx not found in SitePages."
        }

        ### Remove the default Visitors group from My Recertification list
        # Access to recertification items is granted per-item by the governance job
        $listName = "My Recertification"
        Write-Information "`e[32mRemove Visitor group from Recertification list`e[0m"
        $visitorsGroup = Get-PnPProperty -ClientObject (Get-PnPWeb -Connection $cnSite) -Property AssociatedVisitorGroup -Connection $cnSite

        if ($visitorsGroup) {
            $recertList  = Get-PnPList -Identity $listName -Connection $cnSite
            $readRole    = Get-PnPRoleDefinition -Identity "Read" -Connection $cnSite
            Invoke-PnPSPRestMethod -Method Post -Url "/_api/web/lists(guid'$($recertList.Id)')/roleassignments/removeroleassignment(principalid=$($visitorsGroup.Id),roledefid=$($readRole.Id))" -Connection $cnSite -ErrorAction SilentlyContinue
            Write-Information "`e[32mRemoved Default Visitors from $listName.`e[0m"
        }
        else {
            Write-Warning "No associated Visitors group found, nothing to remove from $listName."
        }
    }
}
