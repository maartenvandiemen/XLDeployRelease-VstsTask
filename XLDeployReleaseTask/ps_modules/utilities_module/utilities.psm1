function Convert-ToArrayList
{
	[CmdletBinding()]
	param(
		[Parameter()]
		[string]$String
	)
	if($String)
	{
		Write-Host "Converting string `"$String`" to string array.."
		[string[]]$listString = @()
		#Split string on new lines.
		($String -split '[\n]') | Where {$listString += $_}

		#Get rid of possible empty lines in string array
		$listString  = $listString | where {$_}
		Write-Host "Array count is $($listString.Count)"
		return $listString 
	}
}
