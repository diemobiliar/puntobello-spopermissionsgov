<#
.SYNOPSIS
Set logging preferences based on env Vars
.INPUTS
.OUTPUTS
#>
function Set-LoggingPreferences {
    if ($env:INFORMATION -eq '0' -or $env:INFORMATION -eq $false -or $env:INFORMATION -eq 'false') {
        Write-Information "Loglevel INFORMATION disabled" -InformationAction Continue
        $global:InformationPreference = 'SilentlyContinue'
    }
    else {
        $global:InformationPreference = 'Continue'
    }
    if ($env:VERBOSE -eq '1' -or $env:VERBOSE -eq $true -or $env:VERBOSE -eq 'true') {
        Write-Information "Loglevel VERBOSE enabled" -InformationAction Continue
        $global:VerbosePreference = 'Continue'
    }
    else {
        $global:VerbosePreference = 'SilentlyContinue'
    }
    if ($env:DEBUG -eq '1' -or $env:DEBUG -eq $true -or $env:DEBUG -eq 'true') {
        Write-Information "Loglevel DEBUG enabled" -InformationAction Continue
        $global:DebugPreference = 'Continue'
    }
    else {
        $global:DebugPreference = 'SilentlyContinue'
    }
}
Export-ModuleMember -Function Set-LoggingPreferences

<#
.SYNOPSIS
Get all items from the List with a specific status"
.INPUTS
-ListName [string]
-Status [string]
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
-ListItems [Array]
#>
function Get-ListItemsByStatus ($ListName, $Status, $Connection)
{
    try
    {
        Write-Verbose "Retrieving items with status '$Status' from list '$ListName'"
        $output = Get-PnPListItem -List $ListName -Connection $Connection | Where-Object { $_['spo_RequestStatus'] -eq $Status }
        Write-Verbose "Found $($output.Count) item(s) with status '$Status' in list '$ListName'"
    } catch
    {
        Write-Error "Something went wrong retrieving items with status $Status from list $($ListName): $_"
    }
    return $output
}
Export-ModuleMember -Function Get-ListItemsByStatus

<#
.SYNOPSIS
Extract the HTTP status code from a terminating error raised by Invoke-RestMethod, if any.
.OUTPUTS
[int] or $null when the error carries no HTTP response (e.g. a synthetic "NotFound:" throw, network failure)
#>
function Get-HttpStatusCode ($ErrorRecord)
{
    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response)
    {
        return $null
    }
    try
    {
        return [int]$response.StatusCode
    } catch
    {
        return $null
    }
}

<#
.SYNOPSIS
Determine whether an error represents a confirmed "resource does not exist" (HTTP 404, or a
helper function's synthetic "NotFound: ..." throw) as opposed to a transient/auth/other error.
.OUTPUTS
Boolean
#>
function Test-IsNotFoundError ($ErrorRecord)
{
    if ((Get-HttpStatusCode -ErrorRecord $ErrorRecord) -eq 404)
    {
        return $true
    }
    return $ErrorRecord.Exception.Message -like 'NotFound:*'
}

<#
.SYNOPSIS
Test if an App Registration exists and collect the governed permissions it declares
.INPUTS
-AppID [string]
-RoleId [Array]                    Governed app role IDs
-RoleIdToDisplayName [Hashtable]   Maps a role ID to its spo_PermissionScope choice value
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
The Graph application object (with an added "permissionScope" property listing the declared
governed permissions, separated by "; "), $false if it does not exist, $null on error
#>
function Test-AppExists ($AppID, $RoleId, $RoleIdToDisplayName, $Connection)
{
    $output = $false
    try
    {
        Write-Verbose "Checking if app registration with ID '$AppID' exists"
        $accessToken = Get-PnPAccessToken -Connection $Connection -ResourceTypeName "Graph" -Scopes "Application.Read.All"
        $uri = "https://graph.microsoft.com/v1.0/applications(appId='$AppId')"
        $headers = @{
            Authorization = "Bearer $($accessToken)"
        }

        $App = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

        # Collect all managed permission scopes the app has declared
        $matchedScopes = @()
        foreach ($resourceAccess in $App.requiredResourceAccess.resourceAccess)
        {
            if ($resourceAccess.id -in $RoleId -and $resourceAccess.type -eq "Role")
            {
                $matchedScopes += $RoleIdToDisplayName[$resourceAccess.id]
            }
        }
        if ($matchedScopes.Count -gt 0)
        {
            Write-Verbose "App '$AppID' has matched permission scope(s): $($matchedScopes -join ', ')"
            $App | Add-Member -MemberType NoteProperty -Name "permissionScope" -Value ($matchedScopes -join "; ") -Force
        }

        if ($null -ne $App)
        {
            Write-Verbose "App with ID '$AppID' exists (displayName: $($App.displayName))"
            $output = $App
        }
    } catch
    {
        if (Test-IsNotFoundError -ErrorRecord $_)
        {
            Write-Warning "App with ID $AppID does not exist"
        }
        else
        {
            Write-Error "Failed to check if app with ID $AppID exists (treating as indeterminate, not as 'does not exist'): $_"
            $output = $null
        }
    }
    return $output
}
Export-ModuleMember -Function Test-AppExists

<#
.SYNOPSIS
Test if a User is Owner of an App Registration and returns a boolean
With -returnOwners $true it returns the array of owner objects instead
.INPUTS
-AppID [string]
-UPN [string]          Matched against the owner's userPrincipalName and mail
-returnOwners [bool]
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
Boolean ($null on error), or [Array] of owners with -returnOwners $true
#>
function Get-AppOwner ($AppID, $UPN, $returnOwners, $Connection)
{
    $output = $false
    $owners = @()
    try
    {
        Write-Verbose "Retrieving owners for app with ID '$AppID'"
        $accessToken = Get-PnPAccessToken -Connection $Connection -ResourceTypeName "Graph" -Scopes "Application.Read.All"
        $response = Invoke-RestMethod `
            -Uri "https://graph.microsoft.com/v1.0/applications(appId='$AppID')/owners" `
            -Headers @{'Authorization' = "Bearer $($accessToken)" } `
            -ContentType 'application/json' `
            -Method GET

        if ($null -ne $response.value) {
            # Typical Graph collection response
            $owners = $response.value
        } else {
            # Single object response – wrap it
            $owners = @($response)
        }

        Write-Verbose "Found $($owners.Count) owner(s) for app '$AppID'"

        foreach ($owner in $owners)
        {
            # The requester's address comes from SharePoint, which may hold the mail address rather than the UPN
            if (-not [string]::IsNullOrEmpty($UPN) -and ($owner.userPrincipalName -eq $UPN -or $owner.mail -eq $UPN))
            {
                Write-Verbose "User '$UPN' is an owner of app '$AppID'"
                $output = $true
            }
        }

        if (-not $output -and -not [string]::IsNullOrEmpty($UPN))
        {
            Write-Verbose "User '$UPN' is not listed as an owner of app '$AppID'"
        }

    } catch
    {
        if (Test-IsNotFoundError -ErrorRecord $_)
        {
            Write-Warning "App with ID $AppID (or its owners) not found while checking ownership"
        }
        else
        {
            Write-Error "Failed to get owners for app with ID $($AppID) (treating as indeterminate, not as 'not an owner'): $_"
            $output = $null
        }
    }
    if ($returnOwners -eq $true)
    {
        Write-Verbose "Returning $($owners.Count) owner(s) for app '$AppID'"
        return $owners
    } else
    {
        return $output
    }

}
Export-ModuleMember -Function Get-AppOwner

<#
.SYNOPSIS
Test if an URL is a valid SharePoint Site
.INPUTS
-TargetUrL [string]
.OUTPUTS
Boolean
#>
function Test-Site ($TargetUrl, $Connection)
{
    $output = $false
    try
    {
        Write-Verbose "Checking if site '$TargetUrl' exists"
        $uri = [System.Uri]$TargetUrl
        $graphUrl = "https://graph.microsoft.com/v1.0/sites/$($uri.Host):$($uri.AbsolutePath)"

        $accessToken = Get-PnPAccessToken -Connection $Connection -ResourceTypeName "Graph" -Scopes "Sites.FullControl.All"
        $response = Invoke-RestMethod `
            -Uri $graphUrl `
            -Headers @{'Authorization' = "Bearer $($accessToken)" } `
            -ContentType 'application/json' `
            -Method GET

        if ($response.id)
        {
            Write-Verbose "Site '$($response.webUrl)' exists (siteId: $($response.id))"
            $output = $true
        }
    } catch
    {
        if (Test-IsNotFoundError -ErrorRecord $_)
        {
            Write-Warning "Site with Url $($TargetUrl) not found."
        }
        else
        {
            Write-Error "Failed to check if site $($TargetUrl) exists (treating as indeterminate, not as 'not found'): $_"
            $output = $null
        }
    }
    return $output
}
Export-ModuleMember -Function Test-Site

<#
.SYNOPSIS
Test if a SharePoint list or document library exists in a site
.INPUTS
-SiteUrl [string]
-ListName [string]   Display name of the list or library
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
Boolean
#>
function Test-List ($SiteUrl, $ListName, $Connection)
{
    $output = $false
    try
    {
        Write-Verbose "Checking if list '$ListName' exists in site '$SiteUrl'"
        $siteId = Get-GraphSiteId -SiteUrl $SiteUrl -Connection $Connection
        $listId = Get-GraphListId -SiteId $siteId -ListName $ListName -Connection $Connection
        if ($listId)
        {
            Write-Verbose "List '$ListName' found in site '$SiteUrl' (listId: $listId)"
            $output = $true
        }
    } catch
    {
        if (Test-IsNotFoundError -ErrorRecord $_)
        {
            Write-Warning "List '$ListName' not found in site '$SiteUrl'."
        }
        else
        {
            Write-Error "Failed to check if list '$ListName' exists in site '$SiteUrl' (treating as indeterminate, not as 'not found'): $_"
            $output = $null
        }
    }
    return $output
}
Export-ModuleMember -Function Test-List

<#
.SYNOPSIS
Test if a SharePoint list item exists
.INPUTS
-SiteUrl [string]
-ListName [string]   Display name of the list
-ItemId [string]     Integer ID of the list item
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
Boolean
#>
function Test-ListItem ($SiteUrl, $ListName, $ItemId, $Connection)
{
    $output = $false
    try
    {
        Write-Verbose "Checking if item '$ItemId' exists in list '$ListName' on site '$SiteUrl'"
        $siteId = Get-GraphSiteId -SiteUrl $SiteUrl -Connection $Connection
        $listId = Get-GraphListId -SiteId $siteId -ListName $ListName -Connection $Connection
        $accessToken = Get-PnPAccessToken -Connection $Connection -ResourceTypeName "Graph" -Scopes "Sites.FullControl.All"
        $response = Invoke-RestMethod `
            -Uri "https://graph.microsoft.com/v1.0/sites/$siteId/lists/$listId/items/$ItemId" `
            -Headers @{ Authorization = "Bearer $($accessToken)" } `
            -Method GET
        if ($response.id)
        {
            Write-Verbose "List item '$ItemId' found in list '$ListName' (graphId: $($response.id))"
            $output = $true
        }
    } catch
    {
        if (Test-IsNotFoundError -ErrorRecord $_)
        {
            Write-Warning "List item '$ItemId' not found in list '$ListName' on site '$SiteUrl'."
        }
        else
        {
            Write-Error "Failed to check if item '$ItemId' exists in list '$ListName' on site '$SiteUrl' (treating as indeterminate, not as 'not found'): $_"
            $output = $null
        }
    }
    return $output
}
Export-ModuleMember -Function Test-ListItem

<#
.SYNOPSIS
Test if a file exists in a SharePoint document library
.INPUTS
-SiteUrl [string]
-LibraryName [string]  Display name of the document library
-FilePath [string]     Path relative to the library root, e.g. "folder/report.xlsx"
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
Boolean
#>
function Test-File ($SiteUrl, $LibraryName, $FilePath, $Connection)
{
    $output = $false
    try
    {
        Write-Verbose "Checking if file '$FilePath' exists in library '$LibraryName' on site '$SiteUrl'"
        $siteId = Get-GraphSiteId -SiteUrl $SiteUrl -Connection $Connection
        $result = Get-GraphDriveItemByName -SiteId $siteId -LibraryName $LibraryName -FilePath $FilePath -Connection $Connection
        if ($result.ItemId)
        {
            Write-Verbose "File '$FilePath' found in library '$LibraryName' (driveId: $($result.DriveId), itemId: $($result.ItemId))"
            $output = $true
        }
    } catch
    {
        if (Test-IsNotFoundError -ErrorRecord $_)
        {
            Write-Warning "File '$FilePath' not found in library '$LibraryName' on site '$SiteUrl'."
        }
        else
        {
            Write-Error "Failed to check if file '$FilePath' exists in library '$LibraryName' on site '$SiteUrl' (treating as indeterminate, not as 'not found'): $_"
            $output = $null
        }
    }
    return $output
}
Export-ModuleMember -Function Test-File

<#
.SYNOPSIS
Find the Site, Team or private channel which belongs to the TargetUrl, and its owners
.INPUTS
-TargetUrl [string]
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]   Connection to the target site
.OUTPUTS
TargetType [string], TargetName [string], Owners [Array] of mail addresses / UPNs
#>
function Get-TargetObject ($TargetUrl, $Connection)
{
    try
    {
        Write-Verbose "Resolving target object for URL '$TargetUrl'"
        $site = Get-PnPSite -Includes GroupId, RelatedGroupId -Connection $Connection
        $web = Get-PnPWeb -Includes WebTemplateConfiguration -Connection $Connection
        Write-Verbose "Site template: $($web.WebTemplateConfiguration)"

        if ($web.WebTemplateConfiguration -eq 'GROUP#0') # groupId != 00000-000-0000-00000 && GroupId == relatedGroupId
        {
            $M365Group = Get-PnPMicrosoft365Group -Identity $site.GroupId -Connection $Connection
            $Owners = (Get-PnPMicrosoft365GroupOwners -Identity $site.GroupId -Connection $Connection).UserPrincipalName
            Write-Verbose "Found $($Owners.Count) M365Group-Owner(s)"
            if ($M365Group.HasTeam)
            {
                $targetType = 'Teams'
                $targetName = $M365Group.DisplayName
                Write-Verbose "Site '$($site.Url)' belongs to a Team with displayName '$($M365Group.DisplayName)'"
            } else
            {
                $targetType = 'SharePoint'
                $targetName = $web.Title
                Write-Verbose "Site '$($site.Url)' belongs to a Group-connected SharePoint site with title '$($web.Title)'"
            }
        } elseif ($web.WebTemplateConfiguration -like 'TEAMCHANNEL#*')
        {
            $targetType = 'TeamsPrivateChannel'
            $M365Group = Get-PnPMicrosoft365Group -Identity $site.RelatedGroupId -Connection $Connection
            $targetName = $web.Title
            $privateChannels = Get-PnPTeamsChannel -Team $M365Group.Id -Connection $Connection | Where-Object { $_.MembershipType -eq 'Private' }
            Write-Verbose "Found $($privateChannels.Count) private channel(s) for group '$($M365Group.DisplayName)'"
            foreach ($privateChannel in $privateChannels)
            {
                $privateChannelUrl = (Get-PnPTeamsChannelFilesFolder -Team $M365Group.Id -Channel $privateChannel.Id -Connection $Connection).WebUrl
                # The channel's files folder lives in its own site collection: compare the first
                # five URL segments (https://tenant.sharepoint.com/sites/<site>) with this site.
                if ($null -ne $privateChannelUrl -and (($privateChannelUrl.Split('/')[0..4]) -join '/') -eq $site.Url)
                {
                    Write-Verbose "Site '$($site.Url)' belongs to private channel '$($privateChannel.DisplayName)'"
                    $Owners = (Get-PnPTeamsChannelUser -Team $M365Group.Id -Channel $privateChannel.Id -Role Owner -Connection $Connection).Email
                    Write-Verbose "Found $($Owners.Count) owner(s) for private channel '$($privateChannel.DisplayName)'"
                }
            }
            if ($null -eq $Owners)
            {
                Write-Error "No Owners found for Private Channel"
            }
        } elseif ($web.WebTemplateConfiguration -eq 'SITEPAGEPUBLISHING#0' -or $web.WebTemplateConfiguration -like 'STS#*')
        {
            $targetType = 'SharePointSite'
            $targetName = $web.Title
            Write-Verbose "Site '$($site.Url)' is a standalone SharePoint site with title '$($web.Title)'"
            $OwnerGroup = Get-PnPGroup -AssociatedOwnerGroup -Connection $Connection
            $OwnerGroupMembers = Get-PnPGroupMember -Group $OwnerGroup -Connection $Connection
            $Owners = Get-OwnerEmail -OwnerGroup $OwnerGroupMembers -Connection $Connection
            Write-Verbose "Found $($Owners.Count) owner(s) for site '$($web.Title)'"
        } else
        {
            Write-Error "Unsupported Site Template $($web.WebTemplateConfiguration)"
        }

    } catch
    {
        Write-Error "Failed to get Target Object for URL $($site.Url): $_"
    }
    return $targetType, $targetName, $Owners
}
Export-ModuleMember -Function Get-TargetObject

<#
.SYNOPSIS
Create a new Recertification Item
.INPUTS
-AppID [string]
-AppDisplayName [string]
-AppPermissionScope [string]   spo_PermissionScope choice value
-AppPermission [string]        Read|Write (or other level supported by the scope)
-TargetType [string]
-TargetName [string]
-TargetUrl [Microsoft.SharePoint.Client.FieldUrlValue]
-Status [string]
-NextRecertificationDate [DateTime]
-Reason [string]
-TargetResourceName [string]   List / library name (list, item and file scopes only)
-TargetResourceId [string]     Item ID or file path (item and file scopes only)
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
The created list item; throws on failure
#>
function Add-RecertificationItem ($AppID, $AppDisplayName, $AppPermissionScope, $AppPermission, $TargetType, $TargetName, $TargetUrl, $Status, $NextRecertificationDate, $Reason, $TargetResourceName, $TargetResourceId, $Connection)
{
    try
    {
        Write-Verbose "Creating recertification item for app '$AppDisplayName' ($AppID), scope: '$AppPermissionScope', target: '$TargetUrl'"
        $itemProperties = @{
            spo_App_Id                  = $AppID
            spo_AppDisplayname          = $AppDisplayName
            spo_PermissionScope         = $AppPermissionScope
            spo_Permission              = $AppPermission
            spo_TargetType              = $TargetType
            spo_TargetName              = $TargetName
            spo_TargetUrl               = $TargetUrl
            spo_Status                  = $Status
            spo_nextRecertificationDate = $NextRecertificationDate
            spo_Reason                  = $Reason
        }
        if ($TargetResourceName)
        {
            $itemProperties['spo_TargetResourceName'] = $TargetResourceName
            Write-Verbose "Target resource name: '$TargetResourceName'"
        }
        if ($TargetResourceId)
        {
            $itemProperties['spo_TargetResourceId'] = $TargetResourceId
            Write-Verbose "Target resource ID: '$TargetResourceId'"
        }
        $item = Add-PnPListItem -List '/Lists/Recertification' -Values $itemProperties -Connection $Connection
        Write-Verbose "Recertification item created for app '$AppID' (itemId: $($item.Id))"
    } catch
    {
        Write-Error "Failed to create Recertification Item for App with ID $($AppID): $_"
        throw
    }
    return $item
}
Export-ModuleMember -Function Add-RecertificationItem

<#
.SYNOPSIS
Set item-level permissions on a recertification item:
"Modify without Delete" for Teams / Site owners (the approvers)
"Read" for App owners
.INPUTS
-ItemId [int]
-AppOwners [Array]    Graph owner objects (userPrincipalName)
-SiteOwners [Array]   Mail addresses / UPNs
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
None; throws on failure
#>
function Set-ItemPermissions ($ItemId, $AppOwners, $SiteOwners, $Connection)
{
    try
    {
        Write-Verbose "Setting item-level permissions on recertification item '$ItemId' ($($AppOwners.Count) app owner(s), $($SiteOwners.Count) site owner(s))"
        $appOwnerRole = Get-PnPRoleDefinition -Identity "Read" -Connection $Connection
        if ([string]::IsNullOrEmpty($AppOwnerRole))
        {
            Write-Error "Role 'Read' not found"
            throw "Role 'Read' not found"
        }
        $siteOwnerRole = Get-PnPRoleDefinition -Identity "Modify without Delete" -Connection $Connection
        if ([string]::IsNullOrEmpty($SiteOwnerRole))
        {
            Write-Error "Role 'Modify without Delete' not found"
            throw "Role 'Modify without Delete' not found"
        }
        foreach ($AppOwner in $AppOwners)
        {
            Write-Verbose "Granting 'Read' to app owner '$($AppOwner.userPrincipalName)' on item '$ItemId'"
            $item = Set-PnPListItemPermission -List '/Lists/Recertification' -Identity $itemId -User $AppOwner.userPrincipalName -AddRole $appOwnerRole -Connection $Connection
        }
        foreach ($SiteOwner in $SiteOwners)
        {
            Write-Verbose "Granting 'Modify without Delete' to site owner '$SiteOwner' on item '$ItemId'"
            $item = Set-PnPListItemPermission -List '/Lists/Recertification' -Identity $ItemId -User $SiteOwner -AddRole $siteOwnerRole -Connection $Connection
        }
    } catch
    {
        Write-Error "Error setting item permissions: $_"
        throw "Error setting item permissions: $_"
    }

}
Export-ModuleMember -Function Set-ItemPermissions

<#
.SYNOPSIS
Update the Status and / or Mail status of a Recertification Item
.INPUTS
-ItemId [Int]
-ListName [string]
-Values [Hashtable]
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
None; throws on failure so callers don't continue as if the status had been persisted
#>
function Update-RecertificationItem ($ItemId, $ListName, $Values, $Connection)
{
    try
    {
        Write-Verbose "Updating item '$ItemId' in list '$ListName': $($Values | Out-String)"
        Set-PnPListItem -List $ListName -Identity $ItemId -Values $Values -Connection $Connection | Out-Null
    } catch
    {
        throw "Failed to update Item with ID $ItemId in List $($ListName): $_"
    }
}
Export-ModuleMember -Function Update-RecertificationItem

<#
.SYNOPSIS
Resolve a SharePoint site URL to a Graph site ID
.INPUTS
-SiteUrl [string]
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
[string] Graph site ID
#>
function Get-GraphSiteId ($SiteUrl, $Connection)
{
    Write-Verbose "Resolving Graph site ID for '$SiteUrl'"
    $uri = [System.Uri]$SiteUrl
    $graphUrl = "https://graph.microsoft.com/v1.0/sites/$($uri.Host):$($uri.AbsolutePath)"
    $accessToken = Get-PnPAccessToken -Connection $Connection -ResourceTypeName "Graph" -Scopes "Sites.FullControl.All"
    $response = Invoke-RestMethod -Uri $graphUrl -Headers @{ Authorization = "Bearer $($accessToken)" } -Method GET
    Write-Verbose "Resolved site ID: $($response.id)"
    return $response.id
}
Export-ModuleMember -Function Get-GraphSiteId

<#
.SYNOPSIS
Resolve a SharePoint list display name to a Graph list ID within a site
.INPUTS
-SiteId [string]
-ListName [string]   Display name of the list or document library
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
[string] Graph list ID
#>
function Get-GraphListId ($SiteId, $ListName, $Connection)
{
    Write-Verbose "Resolving Graph list ID for '$ListName' in site '$SiteId'"
    $accessToken = Get-PnPAccessToken -Connection $Connection -ResourceTypeName "Graph" -Scopes "Sites.FullControl.All"
    # Single quotes are escaped by doubling them in OData string literals
    $encodedFilter = [System.Uri]::EscapeDataString("displayName eq '$($ListName -replace "'", "''")'")
    $uri = "https://graph.microsoft.com/v1.0/sites/$SiteId/lists?`$filter=$encodedFilter&`$select=id,displayName"
    $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($accessToken)" } -Method GET
    if (-not $response.value -or $response.value.Count -eq 0)
    {
        throw "NotFound: List '$ListName' not found in site '$SiteId'"
    }
    Write-Verbose "Resolved list ID: $($response.value[0].id) for '$ListName'"
    return $response.value[0].id
}
Export-ModuleMember -Function Get-GraphListId

<#
.SYNOPSIS
Resolve a document library name and an optional file path to a Graph driveId and itemId.
When FilePath is omitted the drive root item is returned (used for library-level permissions).
.INPUTS
-SiteId [string]       Graph site ID
-LibraryName [string]  Display name of the document library
-FilePath [string]     Path relative to the library root, e.g. "folder/report.xlsx" (optional)
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
[hashtable] @{ DriveId; ItemId }
#>
function Get-GraphDriveItemByName ($SiteId, $LibraryName, $FilePath, $Connection)
{
    Write-Verbose "Resolving drive item for library '$LibraryName'$(if ($FilePath) { ", file '$FilePath'" } else { ' (root)' }) in site '$SiteId'"
    $accessToken = Get-PnPAccessToken -Connection $Connection -ResourceTypeName "Graph" -Scopes "Sites.FullControl.All"
    $headers = @{ Authorization = "Bearer $($accessToken)" }

    $drivesResponse = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drives" -Headers $headers -Method GET
    $drive = $drivesResponse.value | Where-Object { $_.name -eq $LibraryName }
    if (-not $drive)
    {
        throw "NotFound: Document library '$LibraryName' not found in site"
    }
    Write-Verbose "Resolved driveId: $($drive.id) for library '$LibraryName'"

    if ([string]::IsNullOrEmpty($FilePath))
    {
        $item = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/drives/$($drive.id)/root" -Headers $headers -Method GET
    }
    else
    {
        # Encode each path segment (EscapeUriString is obsolete and leaves e.g. '#' and '?' unencoded)
        $encodedPath = ($FilePath.Trim('/') -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
        $item = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/drives/$($drive.id)/root:/$encodedPath" -Headers $headers -Method GET
    }
    Write-Verbose "Resolved itemId: $($item.id)$(if ($FilePath) { " for '$FilePath'" })"
    return @{ DriveId = $drive.id; ItemId = $item.id }
}
Export-ModuleMember -Function Get-GraphDriveItemByName

<#
.SYNOPSIS
Grant Lists.SelectedOperations.Selected permission on a specific SharePoint list.
.INPUTS
-AppId [string]
-SiteUrl [string]
-ListName [string]         Display name of the list or document library
-PermissionLevel [string]  Read|Write
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
#>
function Grant-ListPermission ($AppId, $SiteUrl, $ListName, $PermissionLevel, $Connection)
{
    try
    {
        Write-Verbose "Granting '$PermissionLevel' to app '$AppId' on list '$ListName' in site '$SiteUrl'"
        $DisplayName = $(Get-PnPAzureADServicePrincipal -AppId $AppId -Connection $Connection).DisplayName
        Write-Verbose "Resolved app display name: '$DisplayName'"
        Grant-PnPEntraIDAppListPermission -AppId $AppId -DisplayName $DisplayName -Permissions $PermissionLevel -List $ListName -Site $SiteUrl -Connection $Connection
        Write-Information "Granted $PermissionLevel permission to $DisplayName ($AppId) on list '$ListName'"
    } catch
    {
        Write-Error "Failed to grant $PermissionLevel permission to $AppId on list '$ListName': $_"
        throw
    }
}
Export-ModuleMember -Function Grant-ListPermission

<#
.SYNOPSIS
Revoke Lists.SelectedOperations.Selected permission from a specific SharePoint list.
#>
function Revoke-ListPermission ($AppId, $SiteUrl, $ListName, $Connection)
{
    try
    {
        Write-Verbose "Revoking permissions for app '$AppId' on list '$ListName' in site '$SiteUrl'"
        $permissions = Get-PnPEntraIDAppListPermission -List $ListName -AppIdentity $AppId -Site $SiteUrl -Connection $Connection
        Write-Verbose "Found $($permissions.Count) permission(s) on '$ListName' for app '$AppId'"
        foreach ($permission in $permissions)
        {
            Revoke-PnPEntraIDAppListPermission -PermissionId $permission.Id -List $ListName -Site $SiteUrl -Connection $Connection -Force
            Write-Information "Revoked permission $($permission.Id) for $AppId on list '$ListName'"
        }
    } catch
    {
        Write-Error "Failed to revoke permission for $AppId on list '$ListName': $_"
        throw
    }
}
Export-ModuleMember -Function Revoke-ListPermission

<#
.SYNOPSIS
Grant ListItems.SelectedOperations.Selected permission on a specific SharePoint list item
.INPUTS
-AppId [string]
-SiteUrl [string]
-ListName [string]         Display name of the list
-ItemId [string]           SharePoint list item integer ID
-PermissionLevel [string]  Read|Write
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
#>
function Grant-ListItemPermission ($AppId, $SiteUrl, $ListName, $ItemId, $PermissionLevel, $Connection)
{
    try
    {
        Write-Verbose "Granting '$PermissionLevel' to app '$AppId' on item '$ItemId' in list '$ListName' in site '$SiteUrl'"
        $DisplayName = $(Get-PnPAzureADServicePrincipal -AppId $AppId -Connection $Connection).DisplayName
        Write-Verbose "Resolved app display name: '$DisplayName'"
        Grant-PnPEntraIDAppListItemPermission -AppId $AppId -DisplayName $DisplayName -Permissions $PermissionLevel -List $ListName -ListItem $ItemId -Site $SiteUrl -Connection $Connection
        Write-Information "Granted $PermissionLevel permission to $DisplayName ($AppId) on item '$ItemId' in list '$ListName'"
    } catch
    {
        Write-Error "Failed to grant $PermissionLevel permission to $AppId on item '$ItemId' in list '$ListName': $_"
        throw
    }
}
Export-ModuleMember -Function Grant-ListItemPermission

<#
.SYNOPSIS
Revoke ListItems.SelectedOperations.Selected permission from a specific SharePoint list item
#>
function Revoke-ListItemPermission ($AppId, $SiteUrl, $ListName, $ItemId, $Connection)
{
    try
    {
        Write-Verbose "Revoking permissions for app '$AppId' on item '$ItemId' in list '$ListName' in site '$SiteUrl'"
        $permissions = Get-PnPEntraIDAppListItemPermission -List $ListName -ListItem $ItemId -AppIdentity $AppId -Site $SiteUrl -Connection $Connection
        Write-Verbose "Found $($permissions.Count) permission(s) on item '$ItemId' for app '$AppId'"
        foreach ($permission in $permissions)
        {
            Revoke-PnPEntraIDAppListItemPermission -PermissionId $permission.Id -List $ListName -ListItem $ItemId -Site $SiteUrl -Connection $Connection -Force
            Write-Information "Revoked permission $($permission.Id) for $AppId on item '$ItemId' in list '$ListName'"
        }
    } catch
    {
        Write-Error "Failed to revoke permission for $AppId on item '$ItemId' in list '$ListName': $_"
        throw
    }
}
Export-ModuleMember -Function Revoke-ListItemPermission

<#
.SYNOPSIS
Grant Files.SelectedOperations.Selected permission on a specific file in a document library
.INPUTS
-AppId [string]
-SiteUrl [string]
-LibraryName [string]      Display name of the document library
-FilePath [string]         Path relative to the library root, e.g. "folder/report.xlsx"
-PermissionLevel [string]  Read|Write
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
#>
function Grant-FilePermission ($AppId, $SiteUrl, $LibraryName, $FilePath, $PermissionLevel, $Connection)
{
    try
    {
        Write-Verbose "Granting '$PermissionLevel' to app '$AppId' on '$LibraryName/$FilePath' in site '$SiteUrl'"
        $DisplayName = $(Get-PnPAzureADServicePrincipal -AppId $AppId -Connection $Connection).DisplayName
        Write-Verbose "Resolved app display name: '$DisplayName'"
        Grant-PnPEntraIDAppFilePermission -AppId $AppId -DisplayName $DisplayName -Permissions $PermissionLevel -List $LibraryName -Path $FilePath -Site $SiteUrl -Connection $Connection
        Write-Information "Granted $PermissionLevel permission to $DisplayName ($AppId) on '$LibraryName/$FilePath'"
    } catch
    {
        Write-Error "Failed to grant $PermissionLevel permission to $AppId on '$LibraryName/$FilePath': $_"
        throw
    }
}
Export-ModuleMember -Function Grant-FilePermission

<#
.SYNOPSIS
Revoke Files.SelectedOperations.Selected permission from a specific file in a document library
#>
function Revoke-FilePermission ($AppId, $SiteUrl, $LibraryName, $FilePath, $Connection)
{
    try
    {
        Write-Verbose "Revoking permissions for app '$AppId' on '$LibraryName/$FilePath' in site '$SiteUrl'"
        $permissions = Get-PnPEntraIDAppFilePermission -List $LibraryName -Path $FilePath -AppIdentity $AppId -Site $SiteUrl -Connection $Connection
        Write-Verbose "Found $($permissions.Count) permission(s) on '$FilePath' for app '$AppId'"
        foreach ($permission in $permissions)
        {
            Revoke-PnPEntraIDAppFilePermission -PermissionId $permission.Id -List $LibraryName -Path $FilePath -Site $SiteUrl -Connection $Connection -Force
            Write-Information "Revoked permission $($permission.Id) for $AppId on '$LibraryName/$FilePath'"
        }
    } catch
    {
        Write-Error "Failed to revoke permission for $AppId on '$LibraryName/$FilePath': $_"
        throw
    }
}
Export-ModuleMember -Function Revoke-FilePermission

<#
.SYNOPSIS
Grant a Sites.Selected permission (Graph or SPO) on a site
.INPUTS
-AppId [string]
-TargetUrl [string]
-PermissionLevel [string]  Read|Write
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
None; throws on failure
#>
function Grant-APIPermission ($AppId, $TargetUrl, $PermissionLevel, $Connection)
{
    try
    {
        Write-Verbose "Granting '$PermissionLevel' site permission to app '$AppId' on '$TargetUrl'"
        $DisplayName = $(Get-PnPAzureADServicePrincipal -AppId $AppId -Connection $Connection).DisplayName
        Write-Verbose "Resolved app display name: '$DisplayName'"
        Grant-PnPAzureADAppSitePermission -AppId $AppId -Site $TargetUrl -Permissions $PermissionLevel -DisplayName $DisplayName -Connection $Connection
        Write-Information "Granted $PermissionLevel permission to $DisplayName ($AppId) for $TargetUrl"

    } catch
    {
        Write-Error "Failed to grant $PermissionLevel permission to $DisplayName ($AppId) for $($TargetUrl): $_"
        throw
    }
}
Export-ModuleMember -Function Grant-APIPermission

<#
.SYNOPSIS
Revoke all Sites.Selected permissions of an app on a site
.INPUTS
-AppId [string]
-TargetUrl [string]
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
None; throws on failure
#>
function Revoke-APIPermission ($AppId, $TargetUrl, $Connection)
{
    try
    {
        Write-Verbose "Revoking all site permissions for app '$AppId' on '$TargetUrl'"
        $permissions = Get-PnPAzureADAppSitePermission -AppIdentity $AppId -Site $TargetUrl -Connection $Connection
        Write-Verbose "Found $($permissions.Count) permission(s) to revoke for app '$AppId'"
        foreach ($permission in $permissions)
        {
            Revoke-PnPAzureADAppSitePermission -PermissionId $permission.Id -Site $TargetUrl -Connection $Connection -Force
            Write-Information "Revoked $($permission.Roles -join ";") permission with Id $($permission.Id) for $AppId on $TargetUrl"
        }
    } catch
    {
        Write-Error "Failed to revoke permission for $AppId on $($TargetUrl): $_"
        throw
    }
}
Export-ModuleMember -Function Revoke-APIPermission

<#
.SYNOPSIS
Get all Application Registration with selected permission to govern
.OUTPUTS
-AppIDs [Array]
#>
function Get-AppsWithAPIPermission ($RoleId, $RoleIdToDisplayName, $Connection)
{
    $result = @()
    try
    {
        Write-Verbose "Fetching all application registrations to find those with managed API permissions"
        $accessToken = Get-PnPAccessToken -Connection $Connection -ResourceTypeName "Graph" -Scopes "Application.Read.All"
        $applications = @()
        $uri = "https://graph.microsoft.com/v1.0/applications"
        $headers = @{
            Authorization = "Bearer $($accessToken)"
        }

        do
        {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
            $applications += $response.value
            Write-Verbose "Fetched page of applications, total so far: $($applications.Count)"
            $uri = $response.'@odata.nextLink'
        } while ($null -ne $uri)

        Write-Verbose "Evaluating $($applications.Count) application(s) for matching permission scopes"
        foreach ($app in $applications)
        {
            # Collect all managed permission scopes the app has declared (may be multiple)
            $matchedScopes = @()
            foreach ($resourceAccess in $app.requiredResourceAccess.resourceAccess)
            {
                if ($resourceAccess.id -in $RoleId -and $resourceAccess.type -eq "Role")
                {
                    $matchedScopes += $RoleIdToDisplayName[$resourceAccess.id]
                }
            }
            if ($matchedScopes.Count -gt 0)
            {
                $app | Add-Member -MemberType NoteProperty -Name "permissionScope" -Value ($matchedScopes -join "; ") -Force
                Write-Verbose "Found app '$($app.displayName)' ($($app.AppId)) with scope(s): $($app.permissionScope)"
                $result += $app
            }
        }

        return $result | Sort-Object -Property id -Unique
    } catch
    {
        Write-Error "Failed to get Applications with one of the selected permissions: $_"
    }
}
Export-ModuleMember -Function Get-AppsWithAPIPermission

<#
.SYNOPSIS
Get all service principals that hold one of the governed app roles as an actual assignment
(granted permission). Covers principals without an app registration in this tenant, such as
managed identities, which Get-AppsWithAPIPermission cannot find.
.INPUTS
-RoleId [Array]
-RoleIdToDisplayName [Hashtable]
-ExcludeAppId [string]  App ID to skip, e.g. the job's own managed identity
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
-ServicePrincipals [Array] with appId, displayName, servicePrincipalType, permissionScope
#>
function Get-ServicePrincipalsWithAPIPermission ($RoleId, $RoleIdToDisplayName, $ExcludeAppId, $Connection)
{
    $result = @()
    try
    {
        Write-Verbose "Fetching app role assignments of governed permissions on Microsoft Graph and SharePoint Online"
        $accessToken = Get-PnPAccessToken -Connection $Connection -ResourceTypeName "Graph" -Scopes "Application.Read.All"
        $headers = @{
            Authorization = "Bearer $($accessToken)"
        }

        # Resource service principals exposing the governed app roles: Microsoft Graph, Office 365 SharePoint Online
        $resourceAppIds = @('00000003-0000-0000-c000-000000000000', '00000003-0000-0ff1-ce00-000000000000')
        $scopesByPrincipalId = @{}
        foreach ($resourceAppId in $resourceAppIds)
        {
            $uri = "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$resourceAppId')/appRoleAssignedTo?`$top=999"
            do
            {
                $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
                foreach ($assignment in $response.value)
                {
                    if ($assignment.appRoleId -in $RoleId -and $assignment.principalType -eq 'ServicePrincipal')
                    {
                        $scopesByPrincipalId[$assignment.principalId] = @($scopesByPrincipalId[$assignment.principalId]) + $RoleIdToDisplayName[$assignment.appRoleId] | Where-Object { $_ }
                    }
                }
                $uri = $response.'@odata.nextLink'
            } while ($null -ne $uri)
        }
        Write-Verbose "Found $($scopesByPrincipalId.Count) service principal(s) with governed app role assignments"

        # Resolve principal object IDs to appId and type (getByIds accepts up to 1000 IDs per call)
        $principalIds = @($scopesByPrincipalId.Keys)
        for ($i = 0; $i -lt $principalIds.Count; $i += 1000)
        {
            $body = @{
                ids   = @($principalIds[$i..([Math]::Min($i + 999, $principalIds.Count - 1))])
                types = @('servicePrincipal')
            } | ConvertTo-Json
            $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/directoryObjects/getByIds" -Headers $headers -Method Post -Body $body -ContentType 'application/json'
            foreach ($servicePrincipal in $response.value)
            {
                if ($servicePrincipal.appId -eq $ExcludeAppId)
                {
                    Write-Verbose "Skipping excluded service principal '$($servicePrincipal.displayName)' ($($servicePrincipal.appId))"
                    continue
                }
                $permissionScope = ($scopesByPrincipalId[$servicePrincipal.id] | Sort-Object -Unique) -join "; "
                Write-Verbose "Found service principal '$($servicePrincipal.displayName)' ($($servicePrincipal.appId), type: $($servicePrincipal.servicePrincipalType)) with scope(s): $permissionScope"
                $result += [PSCustomObject]@{
                    appId                = $servicePrincipal.appId
                    displayName          = $servicePrincipal.displayName
                    servicePrincipalType = $servicePrincipal.servicePrincipalType
                    permissionScope      = $permissionScope
                }
            }
        }

        return $result
    } catch
    {
        Write-Error "Failed to get service principals with one of the selected permissions: $_"
    }
}
Export-ModuleMember -Function Get-ServicePrincipalsWithAPIPermission

<#
.SYNOPSIS
Get the mail addresses of all members of a SharePoint owner group, expanding nested Entra ID groups
.INPUTS
-OwnerGroup [Array]   Members of the associated owner group (Get-PnPGroupMember)
-Connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
Email address(es) of Owner(s)
#>
function Get-OwnerEmail ($OwnerGroup, $Connection)
{
    $emails = @()
    Write-Verbose "Resolving owner emails from $($OwnerGroup.Count) group member(s)"
    foreach ($owner in $OwnerGroup)
    {
        if ($owner.LoginName -like "i:0#.f|membership|*" -and $null -ne $owner.Email)
        {
            Write-Verbose "Adding direct member of owner group: $($owner.Email)"
            $emails += $owner.Email
        } elseif ($owner.LoginName -like "c:0t.c|tenant|*" )
        {
            $groupmembers = (Get-PnPAzureADGroupMember -Identity $owner.Title -Connection $Connection) | Where-Object { [string]::IsNullOrEmpty($_.UserPrincipalName) -eq $false } | Select-Object -ExpandProperty UserPrincipalName
            Write-Verbose "Adding $($groupmembers.Count) member(s) from Azure AD group '$($owner.Title)': $($groupmembers -join ', ')"
            $emails += $groupmembers
        }

    }
    Write-Verbose "Resolved $($emails.Count) unique owner email(s)"
    return $emails | Sort-Object -Unique
}
