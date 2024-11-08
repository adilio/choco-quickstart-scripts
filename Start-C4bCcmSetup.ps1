#requires -modules C4B-Environment
<#
.SYNOPSIS
C4B Quick-Start Guide CCM setup script

.DESCRIPTION
- Performs the following Chocolatey Central Management setup
    - Install of MS SQL Express
    - Creation and permissions of `ChocolateyManagement` DB
    - Install of all 3 CCM packages, with correct parameters
#>
[CmdletBinding()]
param(
    # Credential used for the ChocolateyManagement DB user
    [Parameter()]
    [ValidateNotNull()]
    [System.Management.Automation.PSCredential]
    $DatabaseCredential = (Get-Credential -Username ChocoUser -Message 'Create a credential for the ChocolateyManagement DB user (document this somewhere)'),

    # Certificate to use for CCM service
    [Parameter()]
    [Alias('Thumbprint')]
    [String]
    $CertificateThumbprint
)
process {
    $DefaultEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    Start-Transcript -Path "$env:SystemDrive\choco-setup\logs\Start-C4bCcmSetup-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    $Packages = (Get-Content $PSScriptRoot\files\chocolatey.json | ConvertFrom-Json).packages

    Set-ChocoEnvironmentProperty -Name DatabaseUser -Value $DatabaseCredential

    # DB Setup
    Write-Host "Installing SQL Server Express"
    $chocoArgs = @('upgrade', 'sql-server-express', "--source='ChocolateyInternal'", '-y', '--no-progress')
    & Invoke-Choco @chocoArgs

    # https://docs.microsoft.com/en-us/sql/tools/configuration-manager/tcp-ip-properties-ip-addresses-tab
    Write-Verbose 'SQL Server: Configuring Remote Access on SQL Server Express.'
    $assemblyList = 'Microsoft.SqlServer.Management.Common', 'Microsoft.SqlServer.Smo', 'Microsoft.SqlServer.SqlWmiManagement', 'Microsoft.SqlServer.SmoExtended'

    foreach ($assembly in $assemblyList) {
        $assembly = [System.Reflection.Assembly]::LoadWithPartialName($assembly)
    }

    $wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer # connects to localhost by default
    $instance = $wmi.ServerInstances | Where-Object { $_.Name -eq 'SQLEXPRESS' }

    $np = $instance.ServerProtocols | Where-Object { $_.Name -eq 'Np' }
    $np.IsEnabled = $true
    $np.Alter()

    $tcp = $instance.ServerProtocols | Where-Object { $_.Name -eq 'Tcp' }
    $tcp.IsEnabled = $true
    $tcp.Alter()

    $tcpIpAll = $tcp.IpAddresses | Where-Object { $_.Name -eq 'IpAll' }

    $tcpDynamicPorts = $tcpIpAll.IpAddressProperties | Where-Object { $_.Name -eq 'TcpDynamicPorts' }
    $tcpDynamicPorts.Value = ""
    $tcp.Alter()

    $tcpPort = $tcpIpAll.IpAddressProperties | Where-Object { $_.Name -eq 'TcpPort' }
    $tcpPort.Value = "1433"
    $tcp.Alter()

    # This section will evaluate which version of SQL Express you have installed, and set a login value accordingly
    $SqlString = (Get-ChildItem -Path 'HKLM:\Software\Microsoft\Microsoft SQL Server').Name |
        Where-Object { $_ -like "HKEY_LOCAL_MACHINE\Software\Microsoft\Microsoft SQL Server\MSSQL*.SQLEXPRESS" } 
    $SqlVersion = $SqlString.Split("\") | Where-Object { $_ -like "MSSQL*.SQLEXPRESS" }
    Write-Verbose 'SQL Server: Setting Mixed Mode Authentication.'
    $null = New-ItemProperty "HKLM:\Software\Microsoft\Microsoft SQL Server\$SqlVersion\MSSQLServer\" -Name 'LoginMode' -Value 2 -Force

    Write-Verbose "SQL Server: Forcing Restart of Instance."
    Restart-Service -Force 'MSSQL$SQLEXPRESS'

    Write-Verbose "SQL Server: Setting up SQL Server Browser and starting the service."
    Set-Service 'SQLBrowser' -StartupType Automatic
    Start-Service 'SQLBrowser'

    Write-Verbose "Firewall: Enabling SQLServer TCP port 1433."
    $null = netsh advfirewall firewall add rule name="SQL Server 1433" dir=in action=allow protocol=TCP localport=1433 profile=any enable=yes service=any
    #New-NetFirewallRule -DisplayName "Allow inbound TCP Port 1433" –Direction inbound –LocalPort 1433 -Protocol TCP -Action Allow

    Write-Verbose "Firewall: Enabling SQL Server browser UDP port 1434."
    $null = netsh advfirewall firewall add rule name="SQL Server Browser 1434" dir=in action=allow protocol=UDP localport=1434 profile=any enable=yes service=any
    #New-NetFirewallRule -DisplayName "Allow inbound UDP Port 1434" –Direction inbound –LocalPort 1434 -Protocol UDP -Action Allow

    # Install prerequisites for CCM
    Write-Host "Installing Chocolatey Central Management Prerequisites"
    $chocoArgs = @('install', 'IIS-WebServer', "--source='windowsfeatures'", '--no-progress', '-y')
    & Invoke-Choco @chocoArgs -ValidExitCodes 0, 3010

    $chocoArgs = @('install', 'IIS-ApplicationInit', "--source='windowsfeatures'" ,'--no-progress', '-y')
    & Invoke-Choco @chocoArgs -ValidExitCodes 0, 3010

    $chocoArgs = @('install', 'dotnet-aspnetcoremodule-v2', "--source='ChocolateyInternal'", "--version='$($Packages.Where{$_.Name -eq 'dotnet-aspnetcoremodule-v2'}.Version)'", '--no-progress', '-y')
    & Invoke-Choco @chocoArgs

    $chocoArgs = @('install', 'dotnet-8.0-runtime', "--source='ChocolateyInternal'", "--version=$($Packages.Where{$_.Name -eq 'dotnet-8.0-runtime'}.Version)", '--no-progress', '-y')
    & Invoke-Choco @chocoArgs

    $chocoArgs = @('install', 'dotnet-8.0-aspnetruntime', "--source='ChocolateyInternal'", "--version=$($Packages.Where{$_.Name -eq 'dotnet-8.0-aspnetruntime'}.Version)", '--no-progress', '-y')
    & Invoke-Choco @chocoArgs

    Write-Host "Creating Chocolatey Central Management Database"
    choco install chocolatey-management-database --source='ChocolateyInternal' -y --package-parameters="'/ConnectionString=Server=Localhost\SQLEXPRESS;Database=ChocolateyManagement;Trusted_Connection=true;'" --no-progress

    # Add Local Windows User:
    $DatabaseUser = $DatabaseCredential.UserName
    $DatabaseUserPw = $DatabaseCredential.GetNetworkCredential().Password
    Add-DatabaseUserAndRoles -DatabaseName 'ChocolateyManagement' -Username $DatabaseUser -SqlUserPw $DatabaseUserPw -CreateSqlUser -DatabaseRoles @('db_datareader', 'db_datawriter')

    # Find FDQN for current machine
    $hostName = [System.Net.Dns]::GetHostName()
    $domainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName

    if (-not $hostName.EndsWith($domainName)) {
        $hostName += "." + $domainName
    }

    Write-Host "Installing Chocolatey Central Management Service"
    $chocoArgs = @('install', 'chocolatey-management-service', "--source='ChocolateyInternal'", '-y', "--package-parameters-sensitive=`"/ConnectionString:'Server=Localhost\SQLEXPRESS;Database=ChocolateyManagement;User ID=$DatabaseUser;Password=$DatabaseUserPw;'`"", '--no-progress')
    if ($CertificateThumbprint) {
        Write-Verbose "Validating certificate is in LocalMachine\TrustedPeople Store"
        if (-not (Get-Item Cert:\LocalMachine\TrustedPeople\$CertificateThumbprint -EA 0) -and -not (Get-Item Cert:\LocalMachine\My\$CertificateThumbprint -EA 0)) {
            Write-Warning "You specified $CertificateThumbprint for use with CCM service, but the certificate is not in the required LocalMachine\TrustedPeople store!"
            Write-Warning "Please place certificate with thumbprint: $CertificateThumbprint in the LocalMachine\TrustedPeople store and re-run this step"
            throw "Certificate not in correct location... exiting."
        } elseif ($MyCertificate = Get-Item Cert:\LocalMachine\My\$CertificateThumbprint -EA 0) {
            Write-Verbose "Copying certificate from 'Personal' store to 'TrustedPeople'"
            Copy-CertToStore $MyCertificate
        } else {
            Write-Verbose "Certificate has been successfully found in correct store"
        }
        $chocoArgs += @("--package-parameters='/CertificateThumbprint=$CertificateThumbprint'")
    }
    & Invoke-Choco @chocoArgs

    Write-Host "Installing Chocolatey Central Management Website"
    $chocoArgs = @('install', 'chocolatey-management-web', "--source='ChocolateyInternal'", '-y', "--package-parameters-sensitive=""'/ConnectionString:Server=Localhost\SQLEXPRESS;Database=ChocolateyManagement;User ID=$DatabaseUser;Password=$DatabaseUserPw;'""", '--no-progress')
    & Invoke-Choco @chocoArgs

    $CcmSvcUrl = Invoke-Choco config get centralManagementServiceUrl -r
    Update-Clixml -Properties @{
        CCMServiceURL        = $CcmSvcUrl
        CCMWebPortal         = "http://localhost/Account/Login"
        DefaultUser          = "ccmadmin"
        DefaultPwToBeChanged = "123qwe"
        CCMDBUser            = $DatabaseUser
        CCMInstallUser       = whoami
    }

    Write-Host "Chocolatey Central Management Setup has now completed" -ForegroundColor Green

    $ErrorActionPreference = $DefaultEap
    Stop-Transcript
}