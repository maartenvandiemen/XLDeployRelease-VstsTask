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

function Send-PackageEx()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true, ValueFromPipeline = $true)][ValidateNotNullOrEmpty()]$packagePath,
        [string][parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "packagePath = $packagePath"
        Write-Verbose "XldServerUrl = $EndpointUrl"
        Write-Verbose "XldServerCredentials Username = $($Credential.UserName)"
    }
    PROCESS
    {
        $env:importScript = "$PSScriptRoot\xld-import.psm1"
        $job = Start-Job { Send-Package $args[0] $args[1] $args[2] } -InitializationScript { Import-Module -Name "$env:importScript" } -ArgumentList $packagePath, $EndpointUrl, $Credential
        Wait-Job $job | Out-Null

        return Receive-Job -Job $job
    }
    END { }
}

<############################################################################################ 
    Uploads the given package to XL Deploy server.
############################################################################################>
function Send-Package()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true, ValueFromPipeline = $true)][ValidateNotNullOrEmpty()]$packagePath,
        [string][parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN
    {
        Write-Verbose "packagePath = $packagePath"
        Write-Verbose "XldServerUrl = $EndpointUrl"
        Write-Verbose "XldServerCredentials Username = $($Credential.UserName)"
    }
    PROCESS
    {
        if (-not (Test-Path $packagePath))
        {
            $errorMessage = ("Package file {0} missing or unable to read." -f $packagePath)
            $exception =  New-Object System.Exception $errorMessage
			$errorRecord = New-Object System.Management.Automation.ErrorRecord $exception, 'XLDPkgUpload', ([System.Management.Automation.ErrorCategory]::InvalidArgument), $packagePath
			$PSCmdlet.ThrowTerminatingError($errorRecord)
        }

		# in case of XLD 6.x beyond, enable TLS 1.2
		if ($EndpointUrl.StartsWith("https", "InvariantCultureIgnoreCase"))
		{		
			[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Ssl3 -bor [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls12
		}

        $fileName = Split-Path $packagePath -leaf
        $fileName = Get-EncodedPathPart($fileName) 

        Add-Type -AssemblyName System.Net.Http
		
		$networkCredential = New-Object -TypeName System.Net.NetworkCredential -ArgumentList @($Credential.UserName, $Credential.Password)
		$httpClientHandler = New-Object -TypeName System.Net.Http.HttpClientHandler
		$httpClientHandler.Credentials = $networkCredential

        $httpClient = New-Object -TypeName System.Net.Http.Httpclient -ArgumentList @($httpClientHandler)

        $packageFileStream = New-Object -TypeName System.IO.FileStream -ArgumentList @($packagePath, [System.IO.FileMode]::Open)
        
		$contentDispositionHeaderValue = New-Object -TypeName  System.Net.Http.Headers.ContentDispositionHeaderValue -ArgumentList @("form-data")
	    $contentDispositionHeaderValue.Name = "fileData"
		$contentDispositionHeaderValue.FileName = $fileName

        $streamContent = New-Object -TypeName System.Net.Http.StreamContent -ArgumentList @($packageFileStream)
        $streamContent.Headers.ContentDisposition = $contentDispositionHeaderValue
        $streamContent.Headers.ContentType = New-Object -TypeName System.Net.Http.Headers.MediaTypeHeaderValue -ArgumentList @("application/octet-stream")
        
        $content = New-Object -TypeName System.Net.Http.MultipartFormDataContent
        $content.Add($streamContent)

        try
        {
			$response = $httpClient.PostAsync("$EndpointUrl/package/upload/$fileName", $content).GetAwaiter().GetResult()

			if (!$response.IsSuccessStatusCode)
			{
				$responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
				$errorMessage = "Status code {0}. Reason {1}. Server reported the following message: {2}." -f $response.StatusCode, $response.ReasonPhrase, $responseBody

				throw [System.Net.Http.HttpRequestException] $errorMessage
			}

			$responseBody = [xml]$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

            $deploymentPackageElement = $responseBody.'udm.DeploymentPackage'
            $provisioningPackageElement = $responseBody.'udm.ProvisioningPackage'
            
            if ($deploymentPackageElement)
            {
                return $deploymentPackageElement.id
            }
            elseif ($provisioningPackageElement)
            {
                return $provisioningPackageElement.id
            }
            else
            {
                throw "Response body doesn't contain a valid message. Import failed."
            }
        }
        catch [Exception]
        {
			throw $_.Exception
        }
        finally
        {
            if($null -ne $httpClient)
            {
                $httpClient.Dispose()
            }

            if($null -ne $response)
            {
                $response.Dispose()
            }
        }
    }
    END { }
}

function Test-ApplicationFolderExists()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$folderName,
        [string][parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN { }
    PROCESS
    {
        $response = Invoke-RestMethod $EndpointUrl/repository/exists/Applications/$folderName -Credential $Credential

		return [boolean]::Parse($response.boolean)
    }
    END { }
}

function New-ApplicationFolder()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$folderName,
        [string][parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN { }
    PROCESS
    {
        $body = "<core.Directory id='Applications/$folderName'></core.Directory>"
        Invoke-RestMethod $EndpointUrl/repository/ci/Applications/$folderName -Method Post -Body $body -ContentType "application/xml" -Credential $Credential

		Write-Verbose "Application folder $folderName is successfully created."

		return $folderName
    }
    END { }
}

function New-ApplicationPath()
{
    [CmdletBinding()]
    param
    (
        [string][parameter(Mandatory = $true)]$fullAppPath,
        [string][parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]$EndpointUrl,
        [System.Management.Automation.PSCredential][parameter(Mandatory = $true)]$Credential
    )
    BEGIN { }
    PROCESS
    {
        [System.Collections.ArrayList]$path = $fullAppPath.Split('/')

		# Remove Applications prefix if exists
		if ($path.Contains("Applications"))
		{
			$path.Remove("Applications")
		}

		# Remove application name
		$path.RemoveAt($path.Count - 1)

		foreach($folder in $path)
		{
			$currentFolder += "/$folder"
			$currentFolder = $currentFolder.TrimStart('/')

			if (-not (Test-ApplicationFolderExists $currentFolder $EndpointUrl $Credential))
			{
				New-ApplicationFolder $currentFolder $EndpointUrl $Credential | Out-Null
			}
		}
    }
    END { }
}