[CmdletBinding()]
param() 
Trace-VstsEnteringInvocation $MyInvocation
try 
{ 
	Import-VstsLocStrings "$PSScriptRoot\Task.json" 

	$action = Get-VstsInput -Name action -Require
    $connectedServiceName = Get-VstsInput -Name connectedServiceName -Require
    $buildDefinition = Get-VstsInput -Name buildDefinition
    $applicationLocation = Get-VstsInput -Name applicationLocation -Require
    $targetEnvironment = Get-VstsInput -Name targetEnvironment -Require
    $rollback = Get-VstsInput -Name rollback -AsBool
    $applicationVersion = Get-VstsInput -Name applicationVersion

	Import-Module $PSScriptRoot\ps_modules\XLD_module\xld-deploy.psm1
	Import-Module $PSScriptRoot\ps_modules\XLD_module\xld-verify.psm1
    $ErrorActionPreference = "Stop"
	
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

	$serviceEndpoint = Get-EndpointData $connectedServiceName

	# Add URL and credentials to default parameters so that we don't need
	# to specify them over and over for this session.
	$PSDefaultParameterValues.Add("*:EndpointUrl", $serviceEndpoint.Url)
	$PSDefaultParameterValues.Add("*:Credential", $serviceEndpoint.Credential)


	# Check server state and validate the address
	Write-Output "Checking XL Deploy server state..."
	if ((Get-ServerState) -ne "RUNNING")
	{
		throw "XL Deploy server not reachable. Address or credentials are invalid or server is not in a running state."
	}
	Write-Output "XL Deploy server is running and credentials are validated."


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
	Write-Output "Start deployment $($deploymentPackageId) to $($targetEnvironment)."
	$deploymentTaskId = New-DeploymentTask $deploymentPackageId $targetEnvironment
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
		if ($taskOutcome -eq "FAILED")
		{
			$errorMessaage = Get-FailedTaskMessage $deploymentTaskId

			ForEach ($line in $($errorMessaage -split "`r`n"))
			{
				if ($line)
				{
					Write-Warning $line
				}
				else
 				{
					Write-Output " "
				}
			}
		}

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
			Write-SetResult "SucceededWithIssues" "Deployment failed - Rollback executed successfully."
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