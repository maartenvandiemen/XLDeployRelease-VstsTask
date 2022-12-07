<#
The scripts in the following file are copied from the task: https://marketplace.visualstudio.com/items?itemName=xebialabs.tfs2015-xl-deploy-plugin
created by Xebia. Some methods are modified.
#>

<############################################################################################
    Checks if the initial or update deployments are necessary, and prepares the
	given deployment.
############################################################################################>
function Get-Deployment()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$deploymentPackageId,
        [string][parameter(Mandatory = $true)]$targetEnvironment,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "deploymentPackageId = $deploymentPackageId"
        Write-Verbose "targetEnvironment = $targetEnvironment"
    }
    PROCESS {
        # Extract application name from deployment Package Id
        # as we expect a value like "Applications/Finance/Simple Web Project/1.0.0.2"
        # we need to split this string on '/' character and get second-last element
        $path = $deploymentPackageId.Split('/')
        $applicationName = $path[$path.Count - 2]
        $version = $path[$path.Count - 1]

        Write-Verbose "applicationName = $applicationName"
        Write-Verbose "version = $version"

        if (Test-ApplicationExists $targetEnvironment $applicationName $EndpointUrl $Credential) {
            return GetDeploymentObject $deploymentPackageId "$targetEnvironment/$applicationName" $EndpointUrl $Credential
        }

        return GetInitialDeploymentObject $deploymentPackageId $targetEnvironment $EndpointUrl $Credential
    }
    END { }
}

<############################################################################################ 
    Prepares an update deployment.
############################################################################################>
function GetDeploymentObject()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$deploymentId,
        [string][parameter(Mandatory = $true)]$deployedApplication,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "deployedApplication = $deployedApplication"
        Write-Verbose "deploymentId = $deploymentId"
    }
    PROCESS
    {
        $uri = "$EndpointUrl/deployment/prepare/update?version=$deploymentId&deployedApplication=$deployedApplication"
        $response = Invoke-RestMethod $uri -Credential $Credential -DisableKeepAlive

        return $response
    }
    END { }
}

<############################################################################################ 
    Prepares an initial deployment.
############################################################################################>
function GetInitialDeploymentObject()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$deploymentId,
        [string][parameter(Mandatory = $true)]$targetEnvironment,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "targetEnvironment = $targetEnvironment"
        Write-Verbose "deploymentId = $deploymentId"
    }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/deployment/prepare/initial?version=$deploymentId&environment=$targetEnvironment" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Prepares all the deployeds for the given deployment. This will keep any previous 
	deployeds present in the deployment object that are already present, unless they cannot
	be deployed with regards to their tags. It will add all the deployeds that are still
	missing. Also filters out the deployeds that do not have any source attached anymore 
	(deployables that were previously present).
############################################################################################>
function Get-Deployed()
{
    [CmdletBinding()]
    param
    (
        [xml][parameter(Mandatory = $true)]$deployment,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "deployment = $($deployment.OuterXml)"
    }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/deployment/prepare/deployeds" -Method Post -Body $deployment -ContentType "application/xml" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Add or override placeholders on a deployed. 
    Based on a provided list with placeholder, values and deployed types.
############################################################################################>
function Set-DeployedPlaceholders()
{
    [CmdletBinding()]
    param
    (
        [xml][parameter(Mandatory = $true)]$deployment,
        [string[]][parameter(Mandatory = $true)]$placeholderList
    )

    # validate if each string is seperated with 3 comma's
    foreach ( $item in $placeholderList )
    {
        if ( ($item -match "(.+),(.+),(.+),(.+)") -and ($item.Split(',').count -eq 4) ) 
        { 
            Write-Verbose "$item : input format validated."

            #validate if deployed type exist
            $type = $item.split(',')[0]
            if ( $deployment.deployment.deployeds.$type )
            {
                Write-Verbose "Deployed $type found."
            }
            else
            {
                Throw "Deployed $type doesn't exist."
            }
        }
        else 
        { 
            Throw "$item doesn't provided with needed format like: deployedType,deployedName,placeholder,value" 
        }
    }

    foreach ( $item in $placeholderList )
    {
        $item = $item.split(',')

        #validate if placeholder exist in deployed.placeholders, if so replace it.
        if ( ($deployment.deployment.deployeds.$($item[0]) | Where-Object {$_.id.split('/')[-1] -eq $($item[1].split('/')[-1])}).placeholders.entry | Where-Object {$_.key -eq $($item[2])} )
        {
            Write-Verbose ("Placeholder found ({0}), it will be replaced with a new value {1}." -f $item[2],$item[3])
            ( ($deployment.deployment.deployeds.$($item[0]) | Where-Object {$_.id.split('/')[-1] -eq $($item[1].split('/')[-1])}).placeholders.entry | Where-Object {$_.key -eq $($item[2])} ).'#text' = $($item[3])
        }

        #validate if placeholder already exists in deployment object.
        Elseif ( ( $deployment.deployment.deployeds.$($item[0]) | Where-Object {$_.id.split('/')[-1] -eq $($item[1].split('/')[-1])} ).($item[2]) )
        {
            Write-Verbose ("Placeholder found ({0}), it will be replaced with a new value {1}." -f $item[2],$item[3])

            try {
                # find deployed that matches deployedType and ciName. If so try to set placeholder with a string. This is needed because not every placeholder is an xml element.
                ( $deployment.deployment.deployeds.$($item[0]) | Where-Object {$_.id.split('/')[-1] -eq $($item[1].split('/')[-1])} ).$($item[2]) = $item[3]
            }
            catch {
                # if simple string replacement won't work we need to replace the xml element with a new one. 
                $element = $deployment.CreateElement($item[2])
                $element.InnerText = $item[3]
                ( $deployment.deployment.deployeds.$($item[0]) | Where-Object {$_.id.split('/')[-1] -eq $($item[1].split('/')[-1])} ).ReplaceChild($element,$deployment.deployment.deployeds.$($item[0]).$($item[2])) | Out-Null
            }
        }
        else # create new xml element
        {
            Write-Verbose ("Placeholder not found ({0}), it will be added with value {1}." -f $item[2],$item[3])

            $element = $deployment.CreateElement($item[2])
            $element.InnerText = $item[3]
            ( $deployment.deployment.deployeds.$($item[0]) | Where-Object {$_.id.split('/')[-1] -eq $($item[1].split('/')[-1])} ).AppendChild($element) | Out-Null
        }
    }
    
    Write-Verbose $deployment.OuterXml

    return $deployment
}

<############################################################################################ 
    Validates the generated deployment. Checks whether all the deployeds that are in the 
	deployment are valid.
############################################################################################>
function Confirm-Deployment()
{
    [CmdletBinding()]
    param
    (
        [xml][parameter(Mandatory = $true)]$deployment,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "deployment = $($deployment.OuterXml)"
    }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/deployment/validate" -Method Post -Body $deployment -ContentType "application/xml" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Rollback a STOPPED or EXECUTED task. Reverting the deployment to the previous state.
	The task will be set to CANCELLED when it was STOPPED , and DONE when it was EXECUTED.
############################################################################################>
function New-RollbackTask()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "taskId = $taskId"

        $taskId = Get-EncodedPathPart($taskId)
    }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/deployment/rollback/$taskId" -Method Post -ContentType "application/xml" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Prepares given deployment and deployeds and creates a new deployment task.
############################################################################################>
function New-DeploymentTask()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$deploymentPackageId,
        [string][parameter(Mandatory = $true)]$targetEnvironment,
        [bool][parameter(Mandatory = $false)]$placeholderOverride,
        [string[]][parameter(Mandatory = $false)]$placeholderList,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "deploymentPackageId = $deploymentPackageId"
        Write-Verbose "targetEnvironment = $targetEnvironment"

        $targetEnvironment = Get-EncodedPathPart($targetEnvironment)
        $deploymentPackageId = Get-EncodedPathPart($deploymentPackageId) 
    }
    PROCESS
    {
        Write-Verbose "Get deployment"
        $initialDeployment = Get-Deployment $deploymentPackageId $targetEnvironment $EndpointUrl $Credential
        Write-Verbose "Prepare deployment"
        $prepDeployment = Get-Deployed $initialDeployment $EndpointUrl $Credential

        if ($placeholderOverride -eq $true) 
        { 
            Write-Verbose "Override placeholders for deployment."
            $prepDeployment = Set-DeployedPlaceholders $prepDeployment $placeholderList
        }

        try
        {
            Write-Verbose "Confirm deployment"
            $confirmedDeployment = Confirm-Deployment $prepDeployment $EndpointUrl $Credential
        }
        catch
        {
            Write-Warning "Found preparation errors:"
            $initialDeployment.SelectNodes("/deployment/deployeds//*/validation-message") | ForEach-Object {
                Write-Host ""
                Write-Warning "Validation error found:"
                Write-Warning "     Level: $($_.level)"
                Write-Warning "     CI: $($_.ci)"
                Write-Warning "     Property: $($_.property)"
                Write-Warning "     Message: $($_."#text")"
            }

            Write-Warning $_
            Throw "Package validation failed! Check preparation errors in log."
        }

        return New-Task $confirmedDeployment $EndpointUrl $Credential
    }
    END { }
}

<############################################################################################ 
    Creates the deployment task.
############################################################################################>
function New-Task()
{
    [CmdletBinding()]
    param
    (
        [xml][parameter(Mandatory = $true)]$deployment,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN { }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/deployment/" -Method Post -Body $deployment -ContentType "application/xml" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Starts a task.
############################################################################################>
function Start-Task()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "taskId = $taskId"
    }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/tasks/v2/$taskId/start" -Method Post -ContentType "application/xml" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Archive an executed task.
############################################################################################>
function Complete-Task()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "taskId = $taskId"

		$taskId = Get-EncodedPathPart($taskId)
    }
    PROCESS
    { 
        return Invoke-RestMethod "$EndpointUrl/tasks/v2/$taskId/archive" -Method Post -ContentType "application/xml" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Returns a task state for a given task ID.
############################################################################################>
function Get-TaskState()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN 
    {
        #Write-Verbose "taskId = $taskId"
    }
    PROCESS
    {
        $task = Get-Task $taskId $EndpointUrl $Credential

        return $task.task.state
    }
    END { }
}

<############################################################################################ 
    Returns a task with blocks for a given task ID.
############################################################################################>
function Get-Task()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN 
    {
        Write-Verbose "taskId = $taskId"
    }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/tasks/v2/$taskId" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Returns a task state for a given task ID.
############################################################################################>
function Get-StepState()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$stepPath,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN 
    {
        Write-Verbose "taskId = $taskId"
        Write-Verbose "stepPath = $stepPath"
    }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/tasks/v2/$taskId/step/$stepPath" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

function Get-Steps()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$blockId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN 
    {
        Write-Verbose "taskId = $taskId"
        Write-Verbose "blockId = $blockId"
    }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/tasks/v2/$taskId/block/$blockId/step" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

function Get-FailedStep()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$blockId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN 
    {
        Write-Verbose "taskId = $taskId"
        Write-Verbose "blockId = $blockId"
    }
    PROCESS
    {

        $steps = Get-Steps $taskId $blockId $EndpointUrl $Credential


        if ($steps.block.hasSteps)
        {
            if ($steps.block.step.Count)
            {
                for ($i=0; $i -le $steps.block.step.Count; $i++)
                {
                    $step = $steps.block.step[$i]
                    $step
                    if ($step.state -eq "FAILED")
                    {
                        return (Get-StepState $taskId "$($blockId)_$($i+1)" $EndpointUrl $Credential)
                    }
                }
            }
            else
            {
                return Get-StepState $taskId "$($blockId)_1" $EndpointUrl $Credential
            }
        }
    }
    END { }
}

function Get-FailedTaskMessage()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN 
    {
        Write-Verbose "taskId = $taskId"
    }
    PROCESS
    {
        $failedBlocks = Get-FailedBlocks $taskId $EndpointUrl $Credential
        $errorMessage = "Deployment failed at:"+ "`r`n"

        for ($i=0; $i -le $failedBlocks.Count; $i++)
        {
            $block = $failedBlocks[$i]

            if ($block.description)
            {
				$block.description
                $errorMessage += "".PadLeft(($i + 1) * 3,'-') + "> " + $block.description + "`r`n"
            }
        }
		
        $lastBlock = $failedBlocks[$failedBlocks.Count - 1]
        $failedStep = Get-FailedStep $taskId $lastBlock.id $EndpointUrl $Credential

        $errorMessage += "".PadLeft(($failedBlocks.Count + 1) * 3,'-') + "> " + $failedStep.step.description + "`r`n" + "`r`n"
        $errorMessage += "Log message:" + "`r`n" + "`r`n"
        $errorMessage += $failedStep.step.log -replace [char]10, "`r`n"
        
        return $errorMessage
    }
    END { }
}

function Set-Message()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$message,
        [string][parameter(Mandatory = $true)]$path
    )
    BEGIN 
    {
    }
    PROCESS
    {
        Add-Content $message -Path $path
    }
    END { }
}

function GetFailedBlocks
{
    param
    (
        $blocks
    )

    $failedBlocks = @()

    foreach($block in $blocks)
    {
        if (-not $block.root -and -not $block.phase -and $block.state -eq 'FAILED')
        {
            $failedBlocks += $block
        }

        if ($block.block)
        {
            $failedBlocks += GetFailedBlocks $block.block
        }
    }

    return $failedBlocks
}

function Get-FailedBlocks()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN 
    {
        Write-Verbose "taskId = $taskId"
    }
    PROCESS
    {
        $task = Get-Task $taskId $EndpointUrl $Credential
        [System.Collections.ArrayList]$blocks = @()
        foreach ($block in (GetFailedBlocks $task.task.block))
        {
            $blocks.Add($block) | Out-Null
        }
        return ,$blocks
    }
}

<############################################################################################ 
    Pools a call and checks the task state every five seconds, until task doesn't get in a
	non running state.
############################################################################################>
function Get-TaskOutcome()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$taskId,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "taskId = $taskId" 
    }
    PROCESS
    {
        $taskState = Get-TaskState $taskId $EndpointUrl $Credential
        
        while (IsTaskRunning($taskState))
        {
            start-sleep -seconds 5

            $taskState = Get-TaskState $taskId $EndpointUrl $Credential
        }

        return $taskState
    }
    END { }
}

<############################################################################################ 
    Checks if the given state is in one of the states known as running states.
############################################################################################>
function IsTaskRunning()
{
    param
    (
        [string][parameter(Mandatory = $true)]$taskState
    )

    Write-Verbose "Current task state is $taskState"

    $runningStates = "QUEUED", "EXECUTING", "ABORTING", "STOPPING", "FAILING", "PENDING"

    foreach($state in $runningStates)
    {
        if ($taskState -eq $state)
        {
            return $true
        }
    }

    return $false
}

<############################################################################################ 
    Checks if the given application exists.
############################################################################################>
function Test-ApplicationExists()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$targetEnvironment,
        [string][parameter(Mandatory = $true)]$applicationName,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "targetEnvironment = $targetEnvironment"
        Write-Verbose "applicationName = $applicationName"
    }
    PROCESS
    {
        $response = Invoke-RestMethod $EndpointUrl/repository/exists/$targetEnvironment/$applicationName -Credential $Credential -DisableKeepAlive

        Write-Verbose ("Application {0} exists: {1} at {2}" -f $applicationName, $response.boolean, $EndpointUrl)

        return [boolean]::Parse($response.boolean)
    }
    END { }
}

<############################################################################################ 
    Gets a CI from the repository
############################################################################################>
function Get-RepositoryCI()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$ID,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN { }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/repository/ci/$($ID)" -Method Get -ContentType "application/xml" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Sets a CI from the repository
############################################################################################>
function Set-RepositoryCI()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$ID,
        [parameter(Mandatory = $true)]$Body,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN { }
    PROCESS
    {
        return Invoke-RestMethod "$EndpointUrl/repository/ci/$($ID)" -Method Put -Body $Body -ContentType "application/xml" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

<############################################################################################ 
    Sets a value on a dictionary entry in a dictionary from the repository
############################################################################################>
function Set-DictionaryEntry()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$Dictionary,
        [string][parameter(Mandatory = $true)]$DictionaryKey,
        [string][parameter(Mandatory = $true)]$DictionaryValue,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN {
        $done = $false
    }
    PROCESS
    {
        $ci = Get-RepositoryCI -ID $Dictionary -EndpointUrl $EndpointUrl -Credential $Credential
        
        foreach ( $entry in $ci.'udm.Dictionary'.EncryptedEntries.entry ) {
            if ($entry.key -ceq $DictionaryKey) {
                $entry.'#text' = $DictionaryValue
                $done = $true
                break
            }
        }

        if ($false -eq $done) {
            foreach ( $entry in $ci.'udm.Dictionary'.Entries.entry ) {
                if ($entry.key -ceq $DictionaryKey) {
                    $entry.'#text' = $DictionaryValue
                    $done = $true
                    break
                }
            }
        }
        
        if ($false -eq $done) {
            Throw ('Cant find dictionary entry "{0}" in dictionary "{1}"' -f $DictionaryKey, $Dictionary)
        }

        Set-RepositoryCI -ID $Dictionary -Body $ci -EndpointUrl $EndpointUrl -Credential $Credential | Out-Null

        Write-Host ('Set succesfully value on dictionary entry "{0}" in dictionary "{1}"' -f $DictionaryKey, $Dictionary)
    }
}

<############################################################################################ 
    Change a CI in the repository
############################################################################################>
function Set-DictionaryEnvrionment()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$Envrionment,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [string[]][parameter(Mandatory = $true)]$Dictionaries,
        [xml][parameter(Mandatory = $true)]$CI,
        [bool][parameter(Mandatory = $true)]$TopOfList,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN { }
    PROCESS
    {
		Write-Verbose $CI
        if($TopOfList)
        {
			Write-Verbose "reverse array."
            [Array]::Reverse($Dictionaries)
            foreach($dictionary in $Dictionaries)
            {
				Write-Verbose "Check if dictionary isn't member"
                if (($CI.SelectNodes("//ci/@ref"))."#text".contains("$dictionary"))
                {
                    Write-Host ("##vso[task.logissue type=warning;]Dictionary $dictionary is already member! Skipping this entry...")
                }
                else
                {
                    Write-Host ("Adding $dictionary to top in xml CI...")
					Write-Verbose "Create CI xml element."
                    $node = $CI.CreateElement("ci")
					Write-Verbose "Set ref attribute."
                    $node.SetAttribute("ref", $dictionary)
					Write-Verbose "Add to CI."
					if($CI.'udm.Environment'.dictionaries.HasChildNodes)
					{
						Write-Verbose "Insert before first child node."
						Write-Verbose ($node.OuterXml | Out-String)
						Write-Verbose "CI before:"
						Write-Verbose ($CI.OuterXml | Out-String)
						$CI.'udm.Environment'.dictionaries.InsertBefore($node, $CI.'udm.Environment'.dictionaries.FirstChild)
						Write-Verbose "CI after:"
						Write-Verbose ($CI.OuterXml | Out-String)
					}
					else
					{
						Write-Verbose "Append child node:"
						Write-Verbose ($node.OuterXml | Out-String)
						Write-Verbose "CI before:"
						Write-Verbose ($CI.OuterXml | Out-String)
						$CI.'udm.Environment'.GetElementsByTagName("dictionaries").AppendChild($node)
						Write-Verbose "CI after:"
						Write-Verbose ($CI.OuterXml | Out-String)
					}
                }
            }
        }
        else
        {
        `	foreach($dictionary in $Dictionaries)
            {
				Write-Verbose "Check if dictionary isn't member"
                if (($CI.SelectNodes("//ci/@ref"))."#text".contains("$dictionary"))
                {
                    Write-Host ("##vso[task.logissue type=warning;]Dictionary $dictionary is already member! Skipping this entry...")
                }
                else
                {
                    Write-Host ("Adding $dictionary to bottom in xml CI...")
					Write-Verbose "Create CI xml element."
                    $node = $CI.CreateElement("ci")
					Write-Verbose "Set ref attribute."
                    $node.SetAttribute("ref", $dictionary)
					Write-Verbose "Add to CI."
					if($CI.'udm.Environment'.dictionaries.HasChildNodes)
					{
						Write-Verbose "Insert after last child node."
						Write-Verbose ($node.OuterXml | Out-String)
						Write-Verbose "CI before:"
						Write-Verbose ($CI.OuterXml | Out-String)
						$CI.'udm.Environment'.dictionaries.InsertAfter($node, $CI.'udm.Environment'.dictionaries.LastChild)
						Write-Verbose "CI after:"
						Write-Verbose ($CI.OuterXml | Out-String)
					}
					else
					{
						Write-Verbose "Append child node."
						Write-Verbose ($node.OuterXml | Out-String)
						Write-Verbose "CI before:"
						Write-Verbose ($CI.OuterXml | Out-String)
						$CI.'udm.Environment'.GetElementsByTagName("dictionaries").AppendChild($node)
						Write-Verbose "CI after:"
						Write-Verbose ($CI.OuterXml | Out-String)
					}
                }
            }
        }
        return Invoke-RestMethod "$EndpointUrl/repository/ci/$($Envrionment)" -Method Put -Body $CI -ContentType "application/xml" -Credential $Credential -DisableKeepAlive
    }
    END { }
}

