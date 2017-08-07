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
    BEGIN { }
    PROCESS
    {
        $response = Invoke-WebRequest $EndpointUrl/server/state -Credential $Credential

		if ($response.StatusCode -eq 200)
		{
			$content = [xml]$response.Content
			return $content.'server-state'.'current-mode'
		}

		Write-Warning "Checking server state returned $($response.StatusCode) - $($response.StatusDescription)"
		
		return "UNREACHABLE"
    }
    END { }
}

<############################################################################################ 
    Checks if the given environment exists.
############################################################################################>
function Test-EnvironmentExists()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$targetEnvironment,
        [string][parameter(Mandatory = $true)]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        if ($targetEnvironment.StartsWith("Environments/", "InvariantCultureIgnoreCase"))
        {
            $targetEnvironment = $targetEnvironment.Substring(13, $targetEnvironment.Length - 13)
        }

        $targetEnvironment = Get-EncodedPathPart($targetEnvironment)
    }
    PROCESS
    {
        $response = Invoke-RestMethod $EndpointUrl/repository/exists/Environments/$targetEnvironment -Credential $Credential

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
	Retrieves the URL, username and password from the specified generic endpoint.
	Only UserNamePassword authentication scheme is supported for XL Deploy.
############################################################################################>
function Get-EndpointData()
{
	[CmdletBinding()]
	param
	(
		[string][parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]$ConnectedServiceName
	)
	BEGIN
	{
		Write-Verbose "ConnectedServiceName = $ConnectedServiceName"
	}
	PROCESS
	{
		$serviceEndpoint = Get-VstsEndpoint -Name $ConnectedServiceName -Require
        $endpoint = @{}

		if (!$serviceEndpoint)
		{
			throw "A Connected Service with name '$ConnectedServiceName' could not be found.  Ensure that this Connected Service was successfully provisioned using the services tab in the Admin UI."
		}

		$authScheme = $serviceEndpoint.Auth.Scheme
		if ($authScheme -ne 'UserNamePassword')
		{
			throw "The authorization scheme $authScheme is not supported by Xl Deploy server."
		}

        if ($serviceEndpoint.Auth.Parameters.UserName)
        {
            $endpoint.Username = $serviceEndpoint.Auth.Parameters.UserName;
        }
        else
        {
            throw "Endpoint username value not specified."
        }

        if ($serviceEndpoint.Auth.Parameters.Password)
        {
            $type = $serviceEndpoint.Auth.Parameters.Password.GetType()
            Write-Verbose "Password field type $type"

            $endpoint.Password = $serviceEndpoint.Auth.Parameters.Password;
        }
        else
        {
            $endpoint.Password = New-Object System.Security.SecureString	
        }

		$securePassword = ConvertTo-SecureString -String $endpoint.Password -asPlainText -Force
        $endpoint.Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $endpoint.Username, $securePassword

        if ($serviceEndpoint.Url)
        {
            $xldServer = ([Uri]($serviceEndpoint.Url)).AbsoluteUri.TrimEnd('/')

            if (-not $xldServer.EndsWith("deployit", "InvariantCultureIgnoreCase"))
            {
                $xldServer = "$xldServer/deployit"
            }

            # takes in consideration both http and https protocol
            if (-not $xldServer.StartsWith("http", "InvariantCultureIgnoreCase"))
            {
                $xldServer = "http://$xldServer"
            }

            $xldServer = $xldServer -as [System.Uri] 
            
            if (-not ($null -ne $xldServer.AbsoluteURI -and $xldServer.Scheme -match '[http|https]'))
            {
                throw "Provided endpoint address is not a valid URL."
            }

			# in case of XLD 6.x beyond, enable TLS 1.2
			if ($xldServer.Scheme -eq "https")
			{	
				[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Ssl3 -bor [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls12
			}
					
            $endpoint.Url = $xldServer
            $endpoint.OriginalUrl = $serviceEndpoint.Url
        }
        else
        {
            #this can't never be the case as the Url filed is mandatory
            throw "XL Deploy server Url is not specified in the Endpoint configuration."
        }

        Write-Verbose "Endpoint Url: $($endpoint.Url)"
        Write-Verbose "Endpoint OriginalUrl: $($endpoint.OriginalUrl)"
        Write-Verbose "Endpoint Username: $($endpoint.Username)"

		return $endpoint
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

<############################################################################################ 
    Verifies if the given is valid path and if the file is a valid manifest file.
############################################################################################>
function Test-ManifestFile()
{
    [CmdletBinding()]
    [OutputType([Boolean])]
    param
    (
        [string][parameter(Mandatory = $true)]$ManifestPath
    )
    BEGIN { }
    PROCESS
    {
        if (-not (Test-Path $ManifestPath -PathType Leaf)) 
        {
	        throw "Manifest file not found. $ManifestPath is not a valid path."
        }

        try
        {
            [xml]$manifest = Get-Content $ManifestPath
        }
        catch [Exception]
        {
            throw "$ManifestPath is not a valid xml document."
        }

        $deploymentPackageElement = $manifest.'udm.DeploymentPackage'
        $provisioningPackageElement = $manifest.'udm.ProvisioningPackage'

        if (-not $deploymentPackageElement -or -not $provisioningPackageElement)
        {
            throw "$ManifestPath is not a valid manifest xml document."
        }
        
        return $true
    }
    END { }
}

function Set-Version()
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param
    (
        [string][parameter(Mandatory = $true)]$ManifestPath,
        [string][parameter(Mandatory = $true)]$Version        
    )
    BEGIN
    {
        if (-not (Test-Path $ManifestPath -PathType Leaf)) 
        {
	        throw "Manifest file not found. $ManifestPath is not a valid path."
        }
        
        if (-not $Version)
        {
            throw "Version number is not specified."
        }
    }
    PROCESS
    {
        if ($pscmdlet.ShouldProcess($ManifestPath))
        {
            try
            {
                [xml]$manifest = Get-Content $ManifestPath
                
                $deploymentPackageElement = $manifest.'udm.DeploymentPackage'
                $provisioningPackageElement = $manifest.'udm.ProvisioningPackage'
                
                if ($deploymentPackageElement)
                {
                    $deploymentPackageElement.version = $Version
                }
                elseif ($provisioningPackageElement)
                {
                    $provisioningPackageElement.version = $Version
                }
                else
                {
                    throw "$ManifestPath is not a valid manifest file."
                }
                
                $manifest.Save($ManifestPath)
            }
            catch [System.Management.Automation.PSInvalidCastException]
            {
                throw "Manifest is not a valid XML document or contains invalid characters. Error: " + $_.Exception.InnerException.Message
            }
            catch [Exception]
            {
                throw "Can't set version on $ManifestPath. Error: " + $_.Exception.Message
            }
        }
    }
    END { } 
}

function Get-PackageInfo()
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
	param
	(
		[string][parameter(Mandatory = $true)]$PackageFullPath,
        [string]$ManifestFileName = "deployit-manifest.xml"
	)
	BEGIN
	{
        Write-Verbose "PackageFullPath = $PackageFullPath"
        Write-Verbose "ManifestFileName = $ManifestFileName"
        
        if (-not (Test-Path -Path $PackageFullPath -PathType Leaf -IsValid))
        {
            throw "Specified manifest file path is not valid. $PackageFullPath"
        }
        
        Add-Type -Assembly System.IO.Compression.FileSystem
	}
	PROCESS
	{
        try
        {
            $archive = [IO.Compression.ZipFile]::OpenRead($PackageFullPath)
		    $manifestFile = $archive.Entries | Where-Object { $_.Name -eq $ManifestFileName } 
        
            $stream = New-Object System.IO.StreamReader -ArgumentList $manifestFile.Open()

            [xml]$manifest = $stream.ReadToEnd()
        }
        catch
        {
            throw 
        }
        finally
        {
            if($null -ne $archive)
            {
                $archive.Dispose()
            }
            
            if($null -ne $stream)
            {
                $stream.Dispose()
            }
        }
        
        $deploymentPackageElement = $manifest.'udm.DeploymentPackage'
        $provisioningPackageElement = $manifest.'udm.ProvisioningPackage'
        
        if ($deploymentPackageElement)
        {
            $version = $deploymentPackageElement.version
            $application = $deploymentPackageElement.application
        }
        elseif ($provisioningPackageElement)
        {
            $version = $provisioningPackageElement.version
            $application = $provisioningPackageElement.application
        }
        else
        {
            throw "$ManifestPath is not a valid manifest xml document."
        }

        $packageInfo = @{ Version = $version; Application = ($application -as [string]).Trim()}
        
        return $packageInfo
	}
	END { }
}

function Get-Package()
{
	[CmdletBinding()]
	param(
		[string][parameter(Mandatory = $true)]$ApplicationId,
		[string][parameter(Mandatory = $true)]$EndpointUrl,
		[System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
	)
	BEGIN {	}
	PROCESS
    {
		$path = "$EndpointUrl/repository/query?type=udm.DeploymentPackage&parent=$ApplicationId&resultsPerPage=-1"

        $response =  Invoke-RestMethod $path -Credential $Credential

        return $response.list.ci | ForEach-Object { $_.ref }
	}
	END
    {
		Write-Verbose "Packages retrieved successfully."
	}
}

function Get-Application()
{
    [CmdletBinding()]
	param
	(
		[string][parameter(Mandatory = $true)]$ManifestPath
	)
	BEGIN
	{
        Write-Verbose "ManifestPath = $ManifestPath"
	}
	PROCESS
	{
        [xml]$manifest = Get-Content $ManifestPath
        
        $deploymentPackageElement = $manifest.'udm.DeploymentPackage'
        $provisioningPackageElement = $manifest.'udm.ProvisioningPackage'

        if ($deploymentPackageElement)
        {
            return ([string]$deploymentPackageElement.application).Trim()
        }
        elseif ($provisioningPackageElement)
        {
            return ([string]$provisioningPackageElement.application).Trim()
        }
        else
        {
            throw "$ManifestPath is not a valid manifest xml document."
        }
	}
	END { }
}

function Test-Package()
{
	[CmdletBinding()]
    [OutputType([System.Boolean])]
	param(
		[string][parameter(Mandatory = $true)]$PackageName,
		[string][parameter(Mandatory = $true)]$EndpointUrl,
		[System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
	)
	BEGIN
    {
        Write-Verbose "Test-Package"
        Write-Verbose "PackageName = $PackageName"
        
        if (-not $PackageName)
        {
            throw "Package name is a mandatory parameter."
        }
    }
	PROCESS
    {
        $path = $PackageName.Split('/')
        $path = $path[0..($path.Length-2)]

        $applicationName = $path -join "/"
        
        Write-Verbose $applicationName

		$packages = Get-Package $applicationName $EndpointUrl $Credential
        
        if ($packages)
        {
			Write-Verbose "Retrieved packages"
            $packages | Write-Verbose
            
            if ($packages -contains $PackageName)
            {
                return $true
            }
        }

        return $false
	}
	END
    {
		Write-Verbose "Packages retrieved successfully."
	}
}