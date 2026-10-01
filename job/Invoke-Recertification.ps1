# Import Modules before log-level is set.
# because loading modules with verbose logging creates a lot of noise
Import-Module "PnP.PowerShell"

if ($env:MSI_ENDPOINT -or $env:IDENTITY_ENDPOINT) {
    $global:modulePath = '/mnt/scripts'
    # Container deployment uploads every file (scripts and mail templates) flat into the
    # same share directory - see infra/main-cae.tf for why nested subfolders aren't used.
    $global:mailsPath = $global:modulePath
    $PSStyle.OutputRendering = [System.Management.Automation.OutputRendering]::PlainText
}
else {
    $global:modulePath = "$((Get-Location -PSProvider FileSystem).ProviderPath)/job"
    $global:mailsPath = "$($global:modulePath)/mails"
}

# Import the solution specific functions
Import-Module "$($global:modulePath)/RecertificationFunctions.psm1" -Force
Import-Module "$($global:modulePath)/MailFunctions.psm1" -Force

# Governed application permissions (app role IDs on Microsoft Graph / SharePoint Online).
# The display names must match the choices of the spo_PermissionScope field in spo/assets/Site.xml.
$roleIdToDisplayName = @{
    "bd61925e-3bf4-4d62-bc0b-06b06c96d95c" = "Files.SelectedOperations.Selected"
    "de4e4161-a10a-4dfd-809c-e328d89aefeb" = "ListItems.SelectedOperations.Selected"
    "23c5a9bd-d900-4ecf-be26-a0689755d9e5" = "Lists.SelectedOperations.Selected"
    "883ea226-0bf2-4a8f-9f9d-92c9162a727d" = "Sites.Selected (Graph)"
    "20d37865-089c-4dee-8c41-6967602d4ac8" = "Sites.Selected (SPO)"
}

$apiRoleId = $roleIdToDisplayName.Keys

# Environment specific settings, injected into the container by infra/main-caj.tf
$siteUrl = $env:SITE_URL
$global:senderMail = $env:SENDER_MAIL
if ([string]::IsNullOrEmpty($siteUrl) -or [string]::IsNullOrEmpty($global:senderMail))
{
    throw "Environment variables SITE_URL and SENDER_MAIL must be set."
}

Set-LoggingPreferences

Write-Information "Running script Invoke-Recertification.ps1" -InformationAction Continue

$cnSite = Connect-PnPOnline -Url $siteUrl -ManagedIdentity -UserAssignedManagedIdentityClientId $env:AZURE_CLIENT_ID -ReturnConnection

# Get new requests
$newRequests = Get-ListItemsByStatus -Connection $cnSite -ListName '/Lists/Requests' -Status 'New'
# Process new requests
if ($newRequests.Count -ge 1)
{
    foreach ($request in $newRequests)
    {
        try
        {
        # Get user object because mail isn't in author information
        $author = Get-PnPUser -Identity $request['Author'].LookupId -Connection $cnSite
        # Test if App-Id exists
        $appExists = Test-AppExists -AppID $request['spo_AppId'].Trim() -RoleId $apiRoleId -RoleIdToDisplayName $roleIdToDisplayName -Connection $cnSite
        $ownerIsValid = Get-AppOwner -AppID $request['spo_AppId'].Trim() -UPN $author.Email -Connection $cnSite
        $targetsiteExists = Test-Site -TargetUrl $request['spo_TargetUrl'].Url -Connection $cnSite
        $permissionScope = $request['spo_PermissionScope']
        # The requested scope must be one the app actually declares, otherwise an approval
        # for e.g. a single list could end up granting a different (broader) permission.
        $scopeIsDeclared = if ($appExists) { $permissionScope -in ($appExists.permissionScope -split '; ') } else { $appExists }
        $targetResourceExists = $true
        if ($permissionScope -eq 'Lists.SelectedOperations.Selected') {
            $targetResourceExists = Test-List -SiteUrl $request['spo_TargetUrl'].Url -ListName $request['spo_TargetResourceName'] -Connection $cnSite
        } elseif ($permissionScope -eq 'ListItems.SelectedOperations.Selected') {
            $targetResourceExists = Test-ListItem -SiteUrl $request['spo_TargetUrl'].Url -ListName $request['spo_TargetResourceName'] -ItemId $request['spo_TargetResourceId'] -Connection $cnSite
        } elseif ($permissionScope -eq 'Files.SelectedOperations.Selected') {
            $targetResourceExists = Test-File -SiteUrl $request['spo_TargetUrl'].Url -LibraryName $request['spo_TargetResourceName'] -FilePath $request['spo_TargetResourceId'] -Connection $cnSite
        }
        # Each Test-*/Get-AppOwner check above returns $null (rather than $false) when it could not
        # be confirmed one way or the other due to an error (e.g. Graph throttling, auth failure) -
        # as opposed to a confirmed "does not exist"/"not valid". Treat that as indeterminate rather
        # than invalid, so a transient error doesn't permanently reject a legitimate request.
        $validationHadError = $null -eq $appExists -or $null -eq $ownerIsValid -or $null -eq $targetsiteExists -or $null -eq $targetResourceExists

        if ($validationHadError)
        {
            Write-Warning "Validation for request '$($request.Id)' could not be completed due to an error retrieving data; it will be re-evaluated on the next run."
        }
        elseif ($appExists -and $ownerIsValid -and $scopeIsDeclared -and $targetsiteExists -and $targetResourceExists)
        {
            # Resolve the target (SharePoint site, Team or private channel) and its owners,
            # who become the approvers of the recertification item.
            $cnTargetSite = Connect-PnPOnline -Url $request['spo_TargetUrl'].Url -ManagedIdentity -UserAssignedManagedIdentityClientId $env:AZURE_CLIENT_ID -ReturnConnection
            $targetType, $targetName, $SiteOwners = Get-TargetObject -TargetUrl $request['spo_TargetUrl'].Url -Connection $cnTargetSite

            # Create Recertification Item
            $DisplayName = (Get-PnPAzureADApp -Identity $request['spo_AppId'].Trim() -Connection $cnSite).DisplayName
            $itemParams = @{
                AppID                  = $request['spo_AppId'].Trim()
                AppDisplayName         = $DisplayName
                AppPermissionScope     = $permissionScope
                AppPermission          = $request['spo_Permission']
                TargetType             = $targetType
                TargetName             = $targetName
                TargetUrl              = $request['spo_TargetUrl']
                Status                 = 'New'
                Reason                 = $request['spo_Reason']
                TargetResourceName     = $request['spo_TargetResourceName']
                TargetResourceId       = $request['spo_TargetResourceId']
                Connection             = $cnSite
            }
            $recertificationItem = Add-RecertificationItem @itemParams

            # Set Item-Level permissions
            $AppOwners = Get-AppOwner -AppID $request['spo_AppId'].Trim() -returnOwners:$true -Connection $cnSite
            Set-ItemPermissions -ItemId $recertificationItem.Id -AppOwners $AppOwners -SiteOwners $SiteOwners -Connection $cnSite

            # Update Request Status
            Update-RecertificationItem -ItemId $request.Id -ListName '/Lists/Requests' -Values @{spo_RequestStatus = 'MovedToRecertificationList' } -Connection $cnSite
            Write-Information "Request $($request.Id) has been moved to Recertification List"

        } else
        {
            $DisplayName = (Get-PnPAzureADApp -Identity $request['spo_AppId'].Trim() -Connection $cnSite -ErrorAction SilentlyContinue).DisplayName
            Update-RecertificationItem -ItemId $request.Id -ListName '/Lists/Requests' -Values @{spo_RequestStatus = 'Invalid' } -Connection $cnSite
            Write-Information ("ValidationFailed: App exists: {0}, Owner is valid: {1}, Scope declared by app: {2}, Site exists: {3}, Target resource exists: {4} (scope: {5})" -f `
                [bool]$appExists,
                [bool]$ownerIsValid,
                [bool]$scopeIsDeclared,
                [bool]$targetsiteExists,
                [bool]$targetResourceExists,
                $permissionScope
            )
            try
            {
                Send-InfoMail -mailStatus "ValidationFailed" -toRecipients  @($author.Email) -ccRecipients @() -app $DisplayName  -siteUrl $request['spo_TargetUrl'].Url -Connection $cnSite
            }
            catch
            {
                Write-Error "Failed to send ValidationFailed mail for request '$($request.Id)': $_"
            }
        }
        }
        catch
        {
            Write-Error "Failed to process new request '$($request.Id)': $_"
        }
    }
} else
{
    Write-Verbose 'No new requests found'
} 

# Process Recertifications

$listItems = Get-PnPListItem -List '/Lists/Recertification' -Connection $cnSite

foreach ($item in $listItems)
{
    # Reset per-item state so values of a previous item are never reused
    $cnTargetSite = $null
    $appOwners = @()
    $siteOwners = @()

    # Unmanaged items have no target, and rejected items whose RejectedMail was sent are finished
    $isFinished = $item['spo_Status'] -eq 'Rejected' -and $item['spo_MailStatus'] -eq 'RejectedMail'
    if ($item['spo_Status'] -ne 'Unmanaged' -and -not $isFinished)
    {
        try
        {
            $cnTargetSite = Connect-PnPOnline -Url $item['spo_TargetUrl'].Url -ManagedIdentity -UserAssignedManagedIdentityClientId $env:AZURE_CLIENT_ID -ReturnConnection
            $appOwners = Get-AppOwner -AppID $item['spo_App_Id'].Trim() -returnOwners:$true -Connection $cnSite
            $targetType, $targetName, $siteOwners = Get-TargetObject -TargetUrl $item['spo_TargetUrl'].Url -Connection $cnTargetSite
        }
        catch
        {
            Write-Error "Failed to resolve target '$($item['spo_TargetUrl'].Url)' for recertification item '$($item.Id)', skipping it in this run: $_"
            continue
        }
    }
    switch ($item['spo_Status'])
    {
        'New'
        {
            try
            {
                # Send Approval Request
                Send-InfoMail -mailStatus "InitialMail" -toRecipients $siteOwners -ccRecipients @() -app $item['spo_AppDisplayname'] -siteUrl $item['spo_TargetUrl'].Url -Connection $cnSite

                # Update Status and MailStatus
                $nextRecertificationDate = (Get-Date).Date
                $values = @{
                    spo_Status                  = "ApprovalRequested"
                    spo_MailStatus              = "InitialMail"
                    spo_nextRecertificationDate = $nextRecertificationDate
                }
                Update-RecertificationItem -ItemId $item.Id -ListName '/Lists/Recertification' -Values $values -Connection $cnSite
            }
            catch
            {
                Write-Error "Failed to send InitialMail for recertification item '$($item.Id)': $_. Status update skipped."
            }
        }

        'ApprovalRequested'        
        {
            switch ($item['spo_MailStatus'])
            {
                "InitialMail" # Send a reminder, if inital mail was sent, and recertification process started 14 days ago
                {
                    if ($item['spo_nextRecertificationDate'] -le (Get-Date).AddDays(-14))
                    {
                        try
                        {
                            # Send Reminder Mail
                            Send-InfoMail -mailStatus "ReminderMail" -toRecipients $siteOwners -ccRecipients @() -app $item['spo_AppDisplayname'] -siteUrl $item['spo_TargetUrl'].Url -Connection $cnSite

                            # Update MailStatus
                            $values = @{
                                spo_MailStatus = 'ReminderMail'
                            }
                            Update-RecertificationItem -ItemId $item.Id -ListName '/Lists/Recertification' -Values $values -Connection $cnSite
                        }
                        catch
                        {
                            Write-Error "Failed to send ReminderMail for recertification item '$($item.Id)': $_. Status update skipped."
                        }
                    }
                }
                "RecertificationMail" # send a reminder, if recertificatin mail was sent, and recertification process started 14 days ago.
                {
                    if ($item['spo_nextRecertificationDate'] -le (Get-Date).AddDays(-14))
                    {
                        try
                        {
                            # Send Reminder Mail
                            Send-InfoMail -mailStatus "ReminderMail" -toRecipients $siteOwners -ccRecipients @() -app $item['spo_AppDisplayname'] -siteUrl $item['spo_TargetUrl'].Url -Connection $cnSite

                            # Update MailStatus
                            $values = @{
                                spo_MailStatus = 'ReminderMail'
                            }
                            Update-RecertificationItem -ItemId $item.Id -ListName '/Lists/Recertification' -Values $values -Connection $cnSite
                        }
                        catch
                        {
                            Write-Error "Failed to send ReminderMail for recertification item '$($item.Id)': $_. Status update skipped."
                        }
                    }
                }
                "ReminderMail"
                {
                    if ($item['spo_nextRecertificationDate'] -le (Get-Date).AddDays(-28))
                    {
                        try
                        {
                            # Send Second Reminder Mail
                            Send-InfoMail -mailStatus "ReminderMail2" -toRecipients $siteOwners -ccRecipients @() -app $item['spo_AppDisplayname'] -siteUrl $item['spo_TargetUrl'].Url -Connection $cnSite

                            # Update MailStatus
                            $values = @{
                                spo_MailStatus = 'ReminderMail2'
                            }
                            Update-RecertificationItem -ItemId $item.Id -ListName '/Lists/Recertification' -Values $values -Connection $cnSite
                        }
                        catch
                        {
                            Write-Error "Failed to send ReminderMail2 for recertification item '$($item.Id)': $_. Status update skipped."
                        }
                    }
                }
                "ReminderMail2"
                { 
                    if ($item['spo_nextRecertificationDate'] -le (Get-Date).AddDays(-35))
                    {
                        # No answer after 35 days: reject automatically. The permission is revoked
                        # and the RejectedMail sent by the 'Rejected' branch in the next run.
                        try
                        {
                            $values = @{
                                spo_Status           = 'Rejected'
                                spo_ApprovalActionBy = 'System'
                                spo_MailStatus       = 'ExpiredMail'
                            }
                            Update-RecertificationItem -ItemId $item.Id -ListName '/Lists/Recertification' -Values $values -Connection $cnSite
                        }
                        catch
                        {
                            Write-Error "Failed to expire recertification item '$($item.Id)': $_"
                        }
                    }
                }
                Default {}
            }
        }
        
        'Approved'
        {
            if ($item['spo_MailStatus'] -in @("InitialMail", "ReminderMail", "ReminderMail2", "RecertificationMail" ))
            {
                try
                {
                    # Grant permissions based on the requested scope
                    switch ($item['spo_PermissionScope'])
                    {
                        { $_ -in @('Sites.Selected (Graph)', 'Sites.Selected (SPO)') }
                        {
                            Grant-APIPermission -AppId $item['spo_App_Id'].Trim() -TargetUrl $item['spo_TargetUrl'].Url -PermissionLevel $item['spo_Permission'] -Connection $cnTargetSite
                        }
                        'Lists.SelectedOperations.Selected'
                        {
                            Grant-ListPermission -AppId $item['spo_App_Id'].Trim() -SiteUrl $item['spo_TargetUrl'].Url -ListName $item['spo_TargetResourceName'] -PermissionLevel $item['spo_Permission'] -Connection $cnSite
                        }
                        'ListItems.SelectedOperations.Selected'
                        {
                            Grant-ListItemPermission -AppId $item['spo_App_Id'].Trim() -SiteUrl $item['spo_TargetUrl'].Url -ListName $item['spo_TargetResourceName'] -ItemId $item['spo_TargetResourceId'] -PermissionLevel $item['spo_Permission'] -Connection $cnSite
                        }
                        'Files.SelectedOperations.Selected'
                        {
                            Grant-FilePermission -AppId $item['spo_App_Id'].Trim() -SiteUrl $item['spo_TargetUrl'].Url -LibraryName $item['spo_TargetResourceName'] -FilePath $item['spo_TargetResourceId'] -PermissionLevel $item['spo_Permission'] -Connection $cnSite
                        }
                        Default
                        {
                            throw "Unsupported permission scope '$($item['spo_PermissionScope'])'"
                        }
                    }

                    Send-InfoMail -mailStatus "ApprovedMail" -toRecipients $siteOwners -ccRecipients $appOwners -app $item['spo_AppDisplayname'] -siteUrl $item['spo_TargetUrl'].Url -Connection $cnSite

                    # Update NextRecertificationDate
                    $nextRecertificationDate = ((Get-Date).AddYears(1)).Date
                    $values = @{
                        spo_nextRecertificationDate = $nextRecertificationDate
                        spo_MailStatus              = 'ApprovedMail'
                    }
                    Update-RecertificationItem -ItemId $item.Id -ListName '/Lists/Recertification' -Values $values -Connection $cnSite
                }
                catch
                {
                    Write-Error "Permission grant failed for recertification item '$($item.Id)', target resource '$($item['spo_TargetResourceId'])' in '$($item['spo_TargetResourceName'])' (app: $($item['spo_App_Id']), scope: $($item['spo_PermissionScope'])): $_. ApprovedMail and status update skipped."
                }
            } elseif ($item['spo_nextRecertificationDate'] -le (Get-Date))
            {
                try
                {
                    Send-InfoMail -mailStatus "RecertificationMail" -toRecipients $siteOwners -ccRecipients @() -app $item['spo_AppDisplayname'] -siteUrl $item['spo_TargetUrl'].Url -Connection $cnSite
                    $values = @{
                        spo_Status = 'ApprovalRequested'
                        spo_MailStatus = 'RecertificationMail'
                    }
                    Update-RecertificationItem -ItemId $item.Id -ListName '/Lists/Recertification' -Values $values -Connection $cnSite
                }
                catch
                {
                    Write-Error "Failed to send RecertificationMail for recertification item '$($item.Id)': $_. Status update skipped."
                }
            }
        }
        'Rejected'
        {
            if ($item['spo_MailStatus'] -ne 'RejectedMail')
            {
                try
                {
                    # Revoke permissions based on the scope
                    switch ($item['spo_PermissionScope'])
                    {
                        { $_ -in @('Sites.Selected (Graph)', 'Sites.Selected (SPO)') }
                        {
                            Revoke-APIPermission -AppId $item['spo_App_Id'].Trim() -TargetUrl $item['spo_TargetUrl'].Url -Connection $cnTargetSite
                        }
                        'Lists.SelectedOperations.Selected'
                        {
                            Revoke-ListPermission -AppId $item['spo_App_Id'].Trim() -SiteUrl $item['spo_TargetUrl'].Url -ListName $item['spo_TargetResourceName'] -Connection $cnSite
                        }
                        'ListItems.SelectedOperations.Selected'
                        {
                            Revoke-ListItemPermission -AppId $item['spo_App_Id'].Trim() -SiteUrl $item['spo_TargetUrl'].Url -ListName $item['spo_TargetResourceName'] -ItemId $item['spo_TargetResourceId'] -Connection $cnSite
                        }
                        'Files.SelectedOperations.Selected'
                        {
                            Revoke-FilePermission -AppId $item['spo_App_Id'].Trim() -SiteUrl $item['spo_TargetUrl'].Url -LibraryName $item['spo_TargetResourceName'] -FilePath $item['spo_TargetResourceId'] -Connection $cnSite
                        }
                        Default
                        {
                            throw "Unsupported permission scope '$($item['spo_PermissionScope'])'"
                        }
                    }

                    Send-InfoMail -mailStatus "RejectedMail" -toRecipients $siteOwners -ccRecipients $appOwners -app $item['spo_AppDisplayname'] -siteUrl $item['spo_TargetUrl'].Url -Connection $cnSite

                    # Update Status
                    $values = @{
                        spo_MailStatus = 'RejectedMail'
                    }
                    Update-RecertificationItem -ItemId $item.Id -ListName '/Lists/Recertification' -Values $values -Connection $cnSite
                }
                catch
                {
                    Write-Error "Permission revoke failed for recertification item '$($item.Id)', target resource '$($item['spo_TargetResourceId'])' in '$($item['spo_TargetResourceName'])' (app: $($item['spo_App_Id']), scope: $($item['spo_PermissionScope'])): $_. RejectedMail and status update skipped."
                }
            }
        }
        'Unmanaged'
        {
            # Notify the governance mailbox once a week for as long as the app stays unmanaged.
            # spo_nextRecertificationDate is reused as "next notification date" for these items.
            if ($null -eq $item['spo_nextRecertificationDate'] -or $item['spo_nextRecertificationDate'] -le (Get-Date))
            {
                try
                {
                    Send-InfoMail -mailStatus "UnmanagedMail" -toRecipients @($global:senderMail) -ccRecipients @() -app "$($item['spo_AppDisplayname']) ($($item['spo_App_Id']))" -Connection $cnSite

                    $values = @{
                        spo_MailStatus              = 'UnmanagedMail'
                        spo_nextRecertificationDate = (Get-Date).Date.AddDays(7)
                    }
                    Update-RecertificationItem -ItemId $item.Id -ListName '/Lists/Recertification' -Values $values -Connection $cnSite
                }
                catch
                {
                    Write-Error "Failed to send UnmanagedMail for recertification item '$($item.Id)': $_. Status update skipped."
                }
            }
        }
    }
}

# Get all Appplication Registration with "*.selected" permission
$appRegistrations = Get-AppsWithAPIPermission -RoleId $apiRoleId -RoleIdToDisplayName $roleIdToDisplayName -Connection $cnSite

# Get all service principals with a granted "*.selected" app role, e.g. managed identities,
# which have no app registration. The job's own managed identity is excluded.
$servicePrincipals = Get-ServicePrincipalsWithAPIPermission -RoleId $apiRoleId -RoleIdToDisplayName $roleIdToDisplayName -ExcludeAppId $env:AZURE_CLIENT_ID -Connection $cnSite
$servicePrincipals = $servicePrincipals | Where-Object { $_.appId -notin $appRegistrations.appId }

foreach ($app in (@($appRegistrations) + @($servicePrincipals) | Where-Object { $_ } | Sort-Object AppId -Unique))
{
    try
    {
        if ($app.appId -notin $listItems.FieldValues.spo_App_Id)
        {
            $itemParams = @{
                AppID               = $app.appId
                AppDisplayName      = $app.displayName
                AppPermissionScope  = $app.permissionScope
                Status              = 'Unmanaged'
                Connection          = $cnSite
            }
            if ($app.servicePrincipalType)
            {
                $itemParams['Reason'] = "Detected via app role assignment on service principal (type: $($app.servicePrincipalType)), not declared on an app registration in this tenant"
            }
            Add-RecertificationItem @itemParams | Out-Null
            Write-Information "Added a new recertification item with status unmanaged for App: $($app.displayName)"
        } 
    } catch
    {
        Write-Error "Error adding recertification item for App: $($app.displayName): $_"
    }  
}
# Remove unmanaged items of apps that meanwhile have a managed (requested) recertification item
$listItems = Get-PnPListItem -List '/Lists/Recertification' -Connection $cnSite
$uniqueAppIds = $listItems | ForEach-Object { $_["spo_App_Id"] } | Sort-Object -Unique

foreach ($appId in $uniqueAppIds)
{
    try
    {
        $unmanagedItems = $listItems | Where-Object { $_["spo_App_Id"] -eq $appId -and $_["spo_Status"] -eq "Unmanaged" }
        Write-Verbose "$($unmanagedItems.Count) unmanaged entries found for App with Id: $($appId)"
        $managedItems = $listItems | Where-Object { $_["spo_App_Id"] -eq $appId -and $_["spo_Status"] -ne "Unmanaged" }
        Write-Verbose "$($managedItems.Count) managed entries found for App with Id: $($appId)"
        if($null -ne $unmanagedItems -and $null -ne $managedItems)
        {
            foreach ($item in $unmanagedItems) {
                Remove-PnPListItem -List '/Lists/Recertification' -Identity $item.Id -Connection $cnSite -Force
                Write-Information "Removed unmanaged item because a managed recertification item exists for App: $($item["spo_AppDisplayname"])"
            }
        }
    } catch
    {
        Write-Error "Error removing unmanaged items for App with Id $($appId): $_"
    }
}
Write-Information "Recertification process completed"