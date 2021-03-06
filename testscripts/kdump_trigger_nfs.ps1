#######################################################################################
## Description:
##  Trigger kernel core dump through NFS under network traffic
## Revision:
##  v1.0.0 - xinhu - 11/25/2019 - Build the script
#######################################################################################


<#
.Synopsis
    Trigger kernel core dump through NFS under network traffic
.Description
    <test>
        <testName>kdump_trigger_nfs</testName>
        <testID>ESX-KDUMP-06</testID>
        <testScript>testscripts/kdump_trigger_nfs.ps1</testScript>
        <RevertDefaultSnapshot>True</RevertDefaultSnapshot>
        <timeout>2400</timeout>
        <testParams>
            <param>TC_COVERED=RHEL7-50872</param>
        </testParams>
        <onError>Continue</onError>
        <noReboot>False</noReboot> 
    </test>
.Parameter vmName
    Name of the test VM.
.Parameter hvServer
    Name of the VIServer hosting the VM.
.Parameter testParams
    Semicolon separated list of test parameters.
#>


# Checking the input arguments
param([String] $vmName, [String] $hvServer, [String] $testParams)
if (-not $vmName) {
    "FAIL: VM name cannot be null!"
    exit 1
}

if (-not $hvServer) {
    "FAIL: hvServer cannot be null!"
    exit 1
}

if (-not $testParams) {
    Throw "FAIL: No test parameters specified"
}


# Output test parameters so they are captured in log file
"TestParams : '${testParams}'"


# Parse test parameters
$rootDir = $null
$sshKey = $null
$ipv4 = $null


$params = $testParams.Split(";")
foreach ($p in $params) {
    $fields = $p.Split("=")
    switch ($fields[0].Trim()) {
        "rootDir" { $rootDir = $fields[1].Trim() }
        "sshKey" { $sshKey = $fields[1].Trim() }
        "ipv4" { $ipv4 = $fields[1].Trim() }
        default {}
    }
}


# Check all parameters are valid
if (-not $rootDir) {
    "Warn : no rootdir was specified"
}
else {
    if ( (Test-Path -Path "${rootDir}") ) {
        Set-Location $rootDir
    }
    else {
        "Warn : rootdir '${rootDir}' does not exist"
    }
}

if ($null -eq $sshKey) {
    "FAIL: Test parameter sshKey was not specified"
    return $False
}

if ($null -eq $ipv4) {
    "FAIL: Test parameter ipv4 was not specified"
    return $False
}



# Source tcutils.ps1
. .\setupscripts\tcutils.ps1
PowerCLIImport
ConnectToVIServer $env:ENVVISIPADDR `
    $env:ENVVISUSERNAME `
    $env:ENVVISPASSWORD `
    $env:ENVVISPROTOCOL


#######################################################################################
## Main Body
#######################################################################################
$retValdhcp = $Failed
$dir = "/boot/grub2/grub.cfg"


# Get the Guest version
$DISTRO = GetLinuxDistro ${ipv4} ${sshKey}
LogPrint "DEBUG: DISTRO: $DISTRO"
if (-not $DISTRO) {
    LogPrint "ERROR: Guest OS version is NULL"
    DisconnectWithVIServer
    return $Aborted
}


# Current version will skip the RHEL6.x.x
if ($DISTRO -eq "RedHat6") {
    LogPrint "ERROR: Guest OS ($DISTRO) isn't supported, MUST UPDATE in Framework / XML / Script"
    DisconnectWithVIServer
    return $Skipped
}


# Change the dir for changing crashkernel for EFI or BIOS on RHEL7/8
$words = $vmName.split('-')
if ($words[-2] -eq "EFI")
{
    $dir = "/boot/efi/EFI/redhat/grub.cfg"
}
LogPrint "DEBUG: dir $dir"


# Function to stop VMB and disconnect with VIserver
Function StopVMB($hvServer,$vmNameB)
{
    $vmObjB = Get-VMHost -Name $hvServer | Get-VM -Name $vmNameB
    Stop-VM -VM $vmObjB -Confirm:$false -RunAsync:$true -ErrorAction SilentlyContinue
    DisconnectWithVIServer
}


# Function to prepare VMB as NFS server
Function PrepareNFSserver($sshKey,$IP_B,$IP_A)
{
    Write-Host -F Green "INFO: Prepare $IP_B as NFS server"
    Write-Output "INFO: Prepare $IP_B as NFS server"
    $result = bin\plink.exe -batch -i ssh\${sshKey} root@${IP_B} "mkdir -p /export/tmp/var/crash && chmod 777 /export/tmp/var/crash && echo '/export/tmp ${IP_A}(rw,sync)' > /etc/exports && systemctl start nfs-server && exportfs -arv && echo `$?"
    if ($result[-1] -ne 0)
    {
        LogPrint "ERROR: Prepare $IP_B as NFS server failed: $result"
        return $false
    }
    return $true
}


# Function to enable NFS method to store vmcore 
Function EnableNFS($sshKey,${IP_A},${IP_B})
{
    LogPrint "INFO: Prepare to enable NFS method to store vmcore on ${IP_A}"
    $result = bin\plink.exe -i ssh\${sshKey} root@$IP_A "sed -i 's?#nfs my.server.com?nfs ${IP_B}?' /etc/kdump.conf"
    $cmd = "mount -t nfs ${IP_B}:/export/tmp /mnt/nfs"
    $result = bin\plink.exe -i ssh\${sshKey} root@$IP_A "mkdir -p /mnt/nfs && $cmd"
    if ($result)
    {
        LogPrint "ERROR: Mount $IP_B failed: $result"
        return $false
    }
    $result = bin\plink.exe -batch -i ssh\${sshKey} root@$IP_A "systemctl restart kdump"
    if ($result)
    {
        LogPrint "ERROR: Restart kdump failed: $result"
        return $false
    }
    return $true
}


# Function to install netperf on vms
Function InstalNetperf(${sshKey},${ip})
{
    LogPrint "INFO: Start to install netperf on ${ip}"
    # Current have a error "don't have command makeinfo" when install netperf, So cannot judge by echo $?
    $result = bin\plink.exe -batch -i ssh\${sshKey} root@${ip} "yum install -y automake && git clone https://github.com/HewlettPackard/netperf.git && cd netperf && ./autogen.sh && ./configure && make; make install; netperf -h; echo `$?"
    if ($result[-1] -eq 127)
    {
        LogPrint "ERROR: Install netperf failed: $result"
        return $false
    }
    return $true
}


# Prepare VMB
$vmOut = Get-VMHost -Name $hvServer | Get-VM -Name $vmName
$vmNameB = $vmName -creplace ("-A$"),"-B"
LogPrint "INFO: RevertSnap $vmNameB..."
$result = RevertSnapshotVM $vmNameB $hvServer
if ($result[-1] -ne $true)
{
    LogPrint "ERROR: RevertSnap $vmNameB failed"
    DisconnectWithVIServer
    return $Aborted
}
$vmObjB = Get-VMHost -Name $hvServer | Get-VM -Name $vmNameB
LogPrint "INFO: Starting $vmNameB..."
Start-VM -VM $vmObjB -Confirm:$false -RunAsync:$true -ErrorAction SilentlyContinue
$ret = WaitForVMSSHReady $vmNameB $hvServer ${sshKey} 300
if ($ret -ne $true)
{
    LogPrint "Failed: Failed to start VM."
    DisconnectWithVIServer
    return $Aborted
}


# Refresh status
$vmObjB = Get-VMHost -Name $hvServer | Get-VM -Name $vmNameB
$IPB = GetIPv4ViaPowerCLI $vmNameB $hvServer


# Prepare VMB as NFS-server
$result= PrepareNFSserver $sshKey $IPB $ipv4
if ($result[-1] -ne $true)
{
    Write-Output "ERROR: Failed to prepare $IPB as NFS server: $result"
    StopVMB $hvServer $vmNameB
    return $Aborted
}


# Prepare the kdump store of VMA as NFS method
LogPrint "INFO: Change the crashkernel = 512M of $ipv4"
$result = bin\plink.exe -batch -i ssh\${sshKey} root@$ipv4 "sed -i 's?crashkernel=auto?crashkernel=512M?' /etc/default/grub && grub2-mkconfig -o $dir && echo `$? "
if ($result -ne 0)
{
    LogPrint "ERROR: Change crashkernel = 512M failed: $result"
    StopVMB $hvServer $vmNameB
    return $Aborted
}


$result = EnableNFS $sshKey $ipv4 $IPB
if ($result[-1] -ne $true)
{
    LogPrint "ERROR: Enable kdump store as NFS method failed: $result"
    StopVMB $hvServer $vmNameB
    return $Aborted
}


# Install Netperf on VMs
$ips=@($ipv4,$IPB)
foreach($ip in $ips)
{
    $IsIns = InstalNetperf $sshKey ${ip}
    if ($IsIns[-1] -ne $true)
    { 
            LogPrint "ERROR: Failed to install netperf on ${ip}: $IsIns"
            StopVMB $hvServer $vmNameB
            return $Aborted
    }
}


# Start to netperf from VMB to VMA(as server)
LogPrint "INFO: Start to netperf from $IPB to ${ipv4}"
$StarS = bin\plink.exe -batch -i ssh\${sshKey} root@${ipv4} "netserver; echo `$?"
if ($StarS[-1] -ne 0)
{
    LogPrint "ERROR: Make ${ipv4} as netserver Failed;  $StarS"
    StopVMB $hvServer $vmNameB
    return $Aborted
}
Start-Process ".\bin\plink.exe" "-batch -i .\ssh\demo_id_rsa.ppk root@${IPB} netperf -t TCP_STREAM-H ${ipv4} -l 300" -PassThru -WindowStyle Hidden


# Trigger the VMA, and check var/crash
LogPrint "INFO: Trigger the $ipv4"
Start-Process ".\bin\plink.exe" "-batch -i .\ssh\demo_id_rsa.ppk root@${ipv4} echo 1 > /proc/sys/kernel/sysrq && echo c > /proc/sysrq-trigger" -PassThru -WindowStyle Hidden
sleep 120
$crash = bin\plink.exe -i ssh\${sshKey} root@$IPB "du -h /export/tmp/var/crash/"
LogPrint "DENUG: Show the result of nfs-server: $crash"
$crash[0] -match "^\d{1,3}M\b"
if ($($matches[0]).Substring(0,$matches[0].length-1) -gt 30)
{
    LogPrint "INFO: $crash"
    $retValdhcp = $Passed
}

StopVMB $hvServer $vmNameB
return $retValdhcp
