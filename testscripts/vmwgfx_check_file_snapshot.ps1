########################################################################################
## Description:
##  Check the file under /dev/snapshot,if open it, no crash.
##
## Revision:
## 	v1.0.0 - ldu - 07/05/2019 - Check the file under /dev/snapshot.
## 	v1.0.1 - boyang - 12/18/2019 - Enhance errors check.
########################################################################################


<#
.Synopsis
    Check the file under /dev/snapshot,if open it, no crash.
.Description

.Parameter vmName
    Name of the test VM.
.Parameter hvServer
    Name of the VIServer hosting the VM.
.Parameter testParams
    Semicolon separated list of test parameters.
#>

param([String] $vmName, [String] $hvServer, [String] $testParams)


# Checking the input arguments
if (-not $vmName)
{
    "FAIL: VM name cannot be null!"
    exit
}

if (-not $hvServer)
{
    "FAIL: hvServer cannot be null!"
    exit
}

if (-not $testParams)
{
    Throw "FAIL: No test parameters specified"
}


# Output test parameters so they are captured in log file
"TestParams : '${testParams}'"


# Parse test parameters
$rootDir = $null
$sshKey = $null
$ipv4 = $null
$logdir = $null

$params = $testParams.Split(";")
foreach ($p in $params)
{
	$fields = $p.Split("=")
	switch ($fields[0].Trim())
	{
		"rootDir"		{ $rootDir = $fields[1].Trim() }
		"sshKey"		{ $sshKey = $fields[1].Trim() }
		"ipv4"			{ $ipv4 = $fields[1].Trim() }
		"TestLogDir"	{ $logdir = $fields[1].Trim()}
        "VMMemory"     { $mem = $fields[1].Trim() }
        "standard_diff"{ $standard_diff = $fields[1].Trim() }
		default			{}
    }
}


# Check all parameters are valid
if (-not $rootDir)
{
	"Warn : no rootdir was specified"
}
else
{
	if ( (Test-Path -Path "${rootDir}") )
	{
		cd $rootDir
	}
	else
	{
		"Warn : rootdir '${rootDir}' does not exist"
	}
}

if ($null -eq $sshKey)
{
	"FAIL: Test parameter sshKey was not specified"
	return $False
}

if ($null -eq $ipv4)
{
	"FAIL: Test parameter ipv4 was not specified"
	return $False
}

if ($null -eq $logdir)
{
	"FAIL: Test parameter logdir was not specified"
	return $False
}


# Source tcutils.ps1
. .\setupscripts\tcutils.ps1
PowerCLIImport
ConnectToVIServer $env:ENVVISIPADDR `
                  $env:ENVVISUSERNAME `
                  $env:ENVVISPASSWORD `
                  $env:ENVVISPROTOCOL


########################################################################################
# Main Body
########################################################################################
$retVal = $Failed


# Check the scsi timeout value in two files.
$vmwgfx = bin\plink.exe -i ssh\${sshKey} root@${ipv4} "lsmod | grep vmwgfx"
if (-not $vmwgfx)
{
	Write-Output "ERROR:vmwgfx not load."
	return $Aborted
}
else
{
	Write-Output "ERROR:vmwgfx loaded."
}

# Open file /dev/snapshot then check guest status and log message.
$open_file = bin\plink.exe -i ssh\${sshKey} root@${ipv4} "cat /dev/snapshot"


# Check the call trace in dmesg file.
$status = CheckCallTrace $ipv4 $sshKey
if (-not $status[-1]) {
    Write-Host -F Red "ERROR: Found $($status[-2]) in msg."
    Write-Output "ERROR: Found $($status[-2]) in msg."
}
else {
    Write-Host -F Red "INFO: NO call trace found."
    Write-Output "INFO: NO call trace found."
    $retVal = $Passed
}


DisconnectWithVIServer
return $retVal
