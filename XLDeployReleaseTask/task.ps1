param() 
Trace-VstsEnteringInvocation $MyInvocation
try 
{ 
	Import-VstsLocStrings "$PSScriptRoot\Task.json" 

	$action = Get-VstsInput -Name action -Require
    	$connectedServiceName = Get-VstsInput -Name connectedServiceName -Require
    	$endpoint = Get-VstsEndpoint -Name $connectedServiceName -Require
    	$buildDefinition = Get-VstsInput -Name buildDefinition
    	$applicationLocation = Get-VstsInput -Name applicationLocation -Require
    	$targetEnvironment = Get-VstsInput -Name targetEnvironment -Require
    	$rollback = Get-VstsInput -Name rollback -AsBool
	$applicationVersion = Get-VstsInput -Name applicationVersion
	
	Import-Module $PSScriptRoot\ps_modules\XLD_module\xld-deploy.psm1
	Import-Module $PSScriptRoot\ps_modules\XLD_module\xld-verify.psm1
	Import-Module $PSScriptRoot\ps_modules\utilities_module\utilities.psm1

	$ErrorActionPreference = "Stop"
	
	[bool]$placeholderOverride = Get-VstsInput -Name placeholderOverride -AsBool
	[string[]]$placeholderList = Convert-ToArrayList (Get-VstsInput -Name placeholderList)
	
	if($action -eq "Deploy application created from build")
	{
        #Check if TFS 2017 is installed
        if((Get-VstsTaskVariable -Name "Release.AttemptNumber"))
        {
		    $buildNumber = Get-VstsTaskVariable -Name "RELEASE.ARTIFACTS.$buildDefinition.BUILDNUMBER"
        }
        else
        {
            Write-Warning "The field BuildDefinition is ignored, not supported on TFS 2015"
            $buildNumber = Get-VstsTaskVariable -Name "Build.BuildNumber"
        }
	}
	else
	{
		$buildNumber = $applicationVersion
	}

	if(!$buildNumber)
	{

	    if($action -eq "Deploy application created from build")
	    {
		    throw "Version for $($buildDefinition) couldn't be determined."
	    }
	    else
	    {
		    throw "Application version seems to be empty."
	    }
	}

	$authScheme = $endpoint.Auth.scheme
	if ($authScheme -ne 'UserNamePassword')
	{
		throw "The authorization scheme $authScheme is not supported by XL Deploy server."
	}

	# Create PSCredential object
	$credential = New-PSCredential $endpoint.Auth.parameters.username $endpoint.Auth.parameters.password
	$serverUrl = Test-EndpointBaseUrl $endpoint.Url

	# Add URL and credentials to default parameters so that we don't need
	# to specify them over and over for this session.
	$PSDefaultParameterValues.Add("*:EndpointUrl", $serverUrl)
	$PSDefaultParameterValues.Add("*:Credential", $credential)


	# Check server state and validate the address
	Write-Output "Checking XL Deploy server state..."
	if ((Get-ServerState) -ne "RUNNING")
	{
		throw "XL Deploy server not in running state."
	}
	Write-Output "XL Deploy server is running."


	if (-not (Test-EnvironmentExists $targetEnvironment)) 
	{
		throw "Specified environment $targetEnvironment doesn't exists."
	}

    $deploymentPackageId = [System.IO.Path]::Combine($applicationLocation, $buildNumber).Replace("\", "/")

	if(-not $deploymentPackageId.StartsWith("Applications/", "InvariantCultureIgnoreCase"))
	{
		$deploymentPackageId = "Applications/$deploymentPackageId"
	}

	if(-not (Test-Package $deploymentPackageId))
	{
		throw "Specified application $deploymentPackageId doesn't exists."
	}

	# create new deployment task
	if ( $placeholderOverride -eq $true ) { $deploymentTaskId = New-DeploymentTask $deploymentPackageId $targetEnvironment $placeholderOverride $placeholderList }
	else { $deploymentTaskId = New-DeploymentTask $deploymentPackageId $targetEnvironment }
    	Write-Output "Start deployment $($deploymentPackageId) to $($targetEnvironment)."
	Start-Task $deploymentTaskId

	$taskOutcome = Get-TaskOutcome $deploymentTaskId

	if ($taskOutcome -eq "EXECUTED" -or $taskOutcome -eq "DONE")
	{
		# archive
		Complete-Task $deploymentTaskId
		Write-Output "Successfully deployed to $targetEnvironment."
	}
	else
	{
		Write-Warning (Get-FailedTaskMessage -taskId $deploymentTaskId | Out-String)
		
		if (!$rollback) 
		{
			throw "Deployment failed."
		}

		Write-Output "Starting rollback."

		# rollback
		$rollbackTaskId = New-RollbackTask $deploymentTaskId

		Start-Task $rollbackTaskId

		$rollbackTaskOutcome = Get-TaskOutcome $rollbackTaskId

		if ($rollbackTaskOutcome -eq "EXECUTED" -or $rollbackTaskOutcome -eq "DONE")
		{
			# archive
			Complete-Task $rollbackTaskId
			throw "Deployment failed, Rollback succesfully executed"
		}
		else
		{
			Write-Warning (Get-FailedTaskMessage -taskId $rollbackTaskId | Out-String)
			throw "Deployment failed and Rollback failed." 
		}
	}
}
finally
{
	Trace-VstsLeavingInvocation $MyInvocation
}
