<#
.SYNOPSIS
Send a notification mail based on an HTML template in the mails folder
.INPUTS
-mailStatus [string]      Template name, e.g. "InitialMail" (file mails/<mailStatus>.html)
-toRecipients [Array]     Mail addresses / UPNs, or Graph user objects
-ccRecipients [Array]     Mail addresses / UPNs, or Graph user objects
-app [string]             Replaces the [App] placeholder
-siteUrl [string]         Replaces the [Url] placeholder
-connection [PnP.PowerShell.Commands.Base.PnPConnection]
.OUTPUTS
None; throws on failure
#>
function Send-InfoMail ($mailStatus, $toRecipients, $ccRecipients, $app, $siteUrl, $connection) {
    $templates = @('ValidationFailed', 'InitialMail', 'RecertificationMail', 'ReminderMail', 'ReminderMail2', 'ApprovedMail', 'RejectedMail', 'UnmanagedMail')
    if ($mailStatus -notin $templates) {
        throw "Unknown mail template '$mailStatus'"
    }
    $mailBody = Get-Content -Path "$global:mailsPath/$mailStatus.html" -Raw

    $mailBody = $mailBody.Replace("[App]", $app).Replace("[Url]", $siteUrl).Replace("[SPOGovSiteUrl]", "$env:SITE_URL/SitePages/Home.aspx")

    if ($mailBody -match '<title>(.*?)</title>') {
        $mailSubject = $matches[1]  # Get the title from the match
    } else {
        $mailSubject = "Default Subject"  # Fallback if no title is found
    }

    $mailParams = @{
        message = @{
            subject = $mailSubject
            body = @{
                contentType = "HTML"
                content = $mailBody
            }
            toRecipients = @(ConvertTo-GraphRecipient -Recipients $toRecipients)
            ccRecipients = @(ConvertTo-GraphRecipient -Recipients $ccRecipients)
        }
        saveToSentItems = "false"
    }

    try {
        Invoke-RestMethod `
        -Uri "https://graph.microsoft.com/v1.0/users/$($global:senderMail)/sendMail" `
        -Headers @{'Authorization' = "Bearer $(Get-PnPAccessToken -Connection $connection)" } `
        -ContentType 'application/json' `
        -Method POST `
        -Body $($mailParams | ConvertTo-Json -Depth 4)

        Write-Information "Mail `"$($mailStatus)`" sent to $($toRecipients -join ', '), cc: $($ccRecipients -join ', ')"
    } catch {
        Write-Error "Something went wrong sending email: $_"
        throw
    }
}
Export-ModuleMember -Function Send-InfoMail

<#
.SYNOPSIS
Convert mail addresses / UPNs or Graph user objects to Graph "recipient" objects
#>
function ConvertTo-GraphRecipient ($Recipients) {
    foreach ($recipient in $Recipients) {
        $address = if ($recipient -is [string]) { $recipient }
                   elseif ($recipient.mail) { $recipient.mail }
                   elseif ($recipient.userPrincipalName) { $recipient.userPrincipalName }
                   else { [string]$recipient }
        @{ emailAddress = @{ address = $address } }
    }
}
