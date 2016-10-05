<#
The scripts in the following file are copied from the task: https://marketplace.visualstudio.com/items?itemName=xebialabs.tfs2015-xl-deploy-plugin
created by Xebia. Some methods are modified.
#>

<############################################################################################ 
    Return information about current server state (is it RUNNING or in MAINTENANCE mode).
############################################################################################>
function Get-ServerState()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    {
        $response = Invoke-RestMethod $EndpointUrl/server/state -Credential $Credential

        return $response.'server-state'.'current-mode'
    }
}

function Test-ExistsInRepository()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$pathInRepository,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        $pathInRepository = Get-EncodedPathPart($pathInRepository)
    }
    PROCESS
    {
        $response = Invoke-RestMethod $EndpointUrl/repository/exists/$pathInRepository -Credential $Credential

        return [boolean]::Parse($response.boolean)
    }
    END { }
}

<############################################################################################ 
    Verifies that the endpoint URL is well formatted and a valid URL.
############################################################################################>
function Test-EndpointBaseUrl()
{
	[CmdletBinding()]
	param
	(
		[Uri][parameter(Mandatory = $true)]$Endpoint
	)
	BEGIN
	{
		Write-Verbose "Endpoint = $Endpoint"
	}
	PROCESS 
	{
		#$xldServer = $serviceEndpoint.Url.AbsoluteUri.TrimEnd('/')
		$xldServer = $Endpoint.AbsoluteUri.TrimEnd('/')

		if (-not $xldServer.EndsWith("deployit", "InvariantCultureIgnoreCase"))
		{
			$xldServer = "$xldServer/deployit"
		}

		# takes in consideration both http and https protocol
		if (-not $xldServer.StartsWith("http", "InvariantCultureIgnoreCase"))
		{
			$xldServer = "http://$xldServer"
		}

		$uri = $xldServer -as [System.Uri] 
		if (-not ($null -ne $uri.AbsoluteURI -and $uri.Scheme -match '[http|https]'))
		{
			throw "Provided endpoint address is not a valid URL."
		}

		return $uri
	}
	END { }
}

<############################################################################################ 
    Given the username and password strings, create a valid PSCredential object.
############################################################################################>
function New-PSCredential()
{
	[CmdletBinding()]
	param
	(
		[string][parameter(Mandatory = $true)]$Username,
		[string][parameter(Mandatory = $true)]$Password
	)
	BEGIN
	{
		#Write-Verbose "Username = $Username"
        #Write-Verbose "Password = $Password"
	}
	PROCESS
	{
		$securePassword = ConvertTo-SecureString -String $Password -asPlainText -Force
		$credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $Username, $securePassword

		return $credential
	}
	END { }
}

<############################################################################################ 
    Encodes each part of the path separately.
############################################################################################>
function Get-EncodedPathPart()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$PartialPath
    )
    BEGIN { }
    PROCESS
    {
        return ($PartialPath -split "/" | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join "/"
    }
    END { }
}

Export-ModuleMember -function *-*