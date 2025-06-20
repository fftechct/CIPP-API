using namespace System.Net

function Invoke-AddGroup {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Identity.Group.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $SelectedTenants = if ('AllTenants' -in $SelectedTenants) { (Get-Tenants).defaultDomainName } else { $Request.body.tenantFilter.value ? $Request.body.tenantFilter.value : $Request.body.tenantFilter }
    Write-LogMessage -headers $Request.Headers -API $APIName -message 'Accessed this API' -Sev Debug


    $GroupObject = $Request.body

    $Results = foreach ($tenant in $SelectedTenants) {
        try {
            $Email = if ($GroupObject.primDomain.value) { "$($GroupObject.username)@$($GroupObject.primDomain.value)" } else { "$($GroupObject.username)@$($tenant)" }
            if ($GroupObject.groupType -in 'Generic', 'azurerole', 'dynamic', 'm365') {

                $BodyParams = [pscustomobject] @{
                    'displayName'      = $GroupObject.displayName
                    'description'      = $GroupObject.description
                    'mailNickname'     = $GroupObject.username
                    mailEnabled        = [bool]$false
                    securityEnabled    = [bool]$true
                    isAssignableToRole = [bool]($GroupObject | Where-Object -Property groupType -EQ 'AzureRole')
                }
                if ($GroupObject.membershipRules) {
                    $BodyParams | Add-Member -NotePropertyName 'membershipRule' -NotePropertyValue ($GroupObject.membershipRules)
                    $BodyParams | Add-Member -NotePropertyName 'membershipRuleProcessingState' -NotePropertyValue 'On'
                    if ($GroupObject.groupType -eq 'm365') {
                        $BodyParams | Add-Member -NotePropertyName 'groupTypes' -NotePropertyValue @('Unified', 'DynamicMembership')
                        $BodyParams.mailEnabled = $true
                    } else {
                        $BodyParams | Add-Member -NotePropertyName 'groupTypes' -NotePropertyValue @('DynamicMembership')
                    }
                    # Skip adding static members if we're using dynamic membership
                    $SkipStaticMembers = $true
                } elseif ($GroupObject.groupType -eq 'm365') {
                    $BodyParams | Add-Member -NotePropertyName 'groupTypes' -NotePropertyValue @('Unified')
                    $BodyParams.mailEnabled = $true
                }
                if ($GroupObject.owners) {
                    $BodyParams | Add-Member -NotePropertyName 'owners@odata.bind' -NotePropertyValue (($GroupObject.owners) | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$($_.value)" })
                    $BodyParams.'owners@odata.bind' = @($BodyParams.'owners@odata.bind')
                }
                if ($GroupObject.members -and -not $SkipStaticMembers) {
                    $BodyParams | Add-Member -NotePropertyName 'members@odata.bind' -NotePropertyValue (($GroupObject.members) | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$($_.value)" })
                    $BodyParams.'members@odata.bind' = @($BodyParams.'members@odata.bind')
                }
                $GraphRequest = New-GraphPostRequest -uri 'https://graph.microsoft.com/beta/groups' -tenantid $tenant -type POST -body (ConvertTo-Json -InputObject $BodyParams -Depth 10) -Verbose
            } else {
                if ($GroupObject.groupType -eq 'dynamicDistribution') {
                    $ExoParams = @{
                        Name               = $GroupObject.displayName
                        RecipientFilter    = $GroupObject.membershipRules
                        PrimarySmtpAddress = $Email
                    }
                    $GraphRequest = New-ExoRequest -tenantid $tenant -cmdlet 'New-DynamicDistributionGroup' -cmdParams $ExoParams
                } else {
                    $ExoParams = @{
                        Name                               = $GroupObject.displayName
                        Alias                              = $GroupObject.username
                        Description                        = $GroupObject.description
                        PrimarySmtpAddress                 = $Email
                        Type                               = $GroupObject.groupType
                        RequireSenderAuthenticationEnabled = [bool]!$GroupObject.allowExternal
                    }
                    if ($GroupObject.owners) {
                        $ExoParams.ManagedBy = @($GroupObject.owners.value)
                    }
                    if ($GroupObject.members) {
                        $ExoParams.Members = @($GroupObject.members.value)
                    }
                    $GraphRequest = New-ExoRequest -tenantid $tenant -cmdlet 'New-DistributionGroup' -cmdParams $ExoParams
                }
            }

            "Successfully created group $($GroupObject.displayName) for $($tenant)"
            Write-LogMessage -headers $Request.Headers -API $APIName -tenant $tenant -message "Created group $($GroupObject.displayName) with id $($GraphRequest.id)" -Sev Info
            $StatusCode = [HttpStatusCode]::OK
        } catch {
            $ErrorMessage = Get-CippException -Exception $_
            Write-LogMessage -headers $Request.Headers -API $APIName -tenant $tenant -message "Group creation API failed. $($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
            "Failed to create group. $($GroupObject.displayName) for $($tenant) $($ErrorMessage.NormalizedError)"
            $StatusCode = [HttpStatusCode]::InternalServerError
        }
    }

    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{'Results' = @($Results) }
        })
}
