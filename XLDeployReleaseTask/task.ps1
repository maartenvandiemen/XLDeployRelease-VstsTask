param() 
Trace-VstsEnteringInvocation $MyInvocation
try 
{ 
	Import-VstsLocStrings "$PSScriptRoot\Task.json" 

	$action = Get-VstsInput -Name action -Require
    $connectedServiceName = Get-VstsInput -Name connectedServiceName -Require
    $endpoint = Get-VstsEndpoint -Name $connectedServiceName -Require
    $applicationLocation = Get-VstsInput -Name applicationLocation -Require
    $targetEnvironment = Get-VstsInput -Name targetEnvironment -Require
    $rollback = Get-VstsInput -Name rollback -AsBool
    $applicationVersion = Get-VstsInput -Name applicationVersion

	Import-Module $PSScriptRoot\xld-deploy.psm1
	Import-Module $PSScriptRoot\xld-verify.psm1
    $ErrorActionPreference = "Stop"
	
	if($action -eq "Deploy application created from build")
	{
		$buildNumber = Get-VstsTaskVariable -Name "Build.BuildNumber"
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


	if (-not $targetEnvironment.StartsWith("Environments/", "InvariantCultureIgnoreCase"))
	{
		$targetEnvironment = "Environments/$targetEnvironment"
	}

	if (-not (Test-ExistsInRepository $targetEnvironment)) 
	{
		throw "Specified environment $targetEnvironment doesn't exists."
	}

	if(-not $applicationLocation.StartsWith("Applications/", "InvariantCultureIgnoreCase"))
	{
		$applicationLocation = "Applications/$applicationLocation"
	}

	if(-not (Test-ExistsInRepository $applicationLocation))
	{
		throw "Specified application $applicationLocation doesn't exists."
	}

	# create new deployment task
	$deploymentPackageId = [System.IO.Path]::Combine($applicationLocation, $buildNumber).Replace("\", "/")
	$deploymentTaskId = New-DeploymentTask $deploymentPackageId $targetEnvironment

	Start-Task $deploymentTaskId

	$taskOutcome = Get-TaskOutcome $deploymentTaskId

	#Implemented retry mechanism because sometimes the deployment is failing in combination with the IIS deployment plugin of XL Deploy
	#Maximum number of retries: 3
	$retryCounter = 1
	while(($taskOutcome -eq "FAILED" -or $taskOutcome -eq "STOPPED" -or $taskOutcome -eq "CANCELLED") -and $retryCounter -lt 5)
	{
		Write-Output "Deployment failed. Number of times retried: $retryCounter"
		Start-Task $deploymentTaskId
		$taskOutcome = Get-TaskOutcome $deploymentTaskId
		$retryCounter++
	}
	

	if ($taskOutcome -eq "EXECUTED" -or $taskOutcome -eq "DONE")
	{
		# archive
		Complete-Task $deploymentTaskId
		Write-Output "Successfully deployed to $targetEnvironment."
	}
	else
	{
		if (!$shouldRollback) 
		{
			throw "Deployment failed."
		}

		Write-Warning "Deployment failed."
		Write-Output ("##vso[task.complete result=SucceededWithIssues;]Deployment failed.")
        
		Write-Output "Starting rollback."

		# rollback
		$rollbackTaskId = New-RollbackTask $deploymentTaskId

		Start-Task $rollbackTaskId

		$rollbackTaskOutcome = Get-TaskOutcome $rollbackTaskId

		if ($rollbackTaskOutcome -eq "EXECUTED" -or $rollbackTaskOutcome -eq "DONE")
		{
			# archive
			Complete-Task $rollbackTaskId
			Write-Output "Rollback executed successfully."
		}
		else
		{
			throw "Rollback failed." 
		}
	}
}
finally
{
	Trace-VstsLeavingInvocation $MyInvocation
}