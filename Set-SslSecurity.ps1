#requires -modules C4B-Environment
using namespace System.Net.Sockets
using namespace System.Net.Security
using namespace System.Security.Cryptography.X509Certificates
<#
.SYNOPSIS
Generates or retrieves certificates and generates SSL bindings for
Central Management and Nexus.

.DESCRIPTION
Removes any existing certificates which have the subject "chocoserver" to avoid
issues, and then either generates or retrieves the required certificate. The
certificate is placed in the required local machine store, and then the script
generates SSL bindings for both Nexus and the Central Management website using the
certificate.
#>
[CmdletBinding(DefaultParameterSetName='SelfSigned')]
[OutputType([string])]
param(
    # The certificate thumbprint that identifies the target SSL certificate in
    # the local machine certificate stores.
    # Ignored if supplied alongside -Subject.
    [Parameter(ValueFromPipeline, ParameterSetName='Thumbprint')]
    [ArgumentCompleter({
        Get-ChildItem Cert:\LocalMachine\TrustedPeople | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(
                $_.Thumbprint,
                $_.Thumbprint,
                "ParameterValue",
                ($_.Subject -replace "^CN=(?<FQDN>.+),?.*$",'${FQDN}')
            )
        }
    })]
    [string]
    $Thumbprint = $(
        Get-ChildItem Cert:\LocalMachine\TrustedPeople -Recurse | Sort-Object {
            $_.Issuer -eq $_.Subject # Prioritise any certificates above self-signed
        } | Select-Object -ExpandProperty Thumbprint -First 1
    ),

    # The certificate subject that identifies the target SSL certificate in
    # the local machine certificate stores.
    [Parameter(ParameterSetName='Subject')]
    [string]
    $Subject,

    # If using a wildcard certificate, provide a DNS name you want to use to access services secured by the certificate.
    [Parameter(ParameterSetName='Subject')]
    [Parameter(ParameterSetName='Thumbprint')]
    [string]
    $CertificateDnsName = $(
        if (-not (Get-Command Get-ChocoEnvironmentProperty -ErrorAction SilentlyContinue)) {. $PSScriptRoot\scripts\Get-Helpers.ps1}
        Get-ChocoEnvironmentProperty CertSubject
    ),

    # API key of your Nexus repo, to add to the source setup on C4B Server.
    [string]$NuGetApiKey = $(
        if (-not (Get-Command Get-ChocoEnvironmentProperty -ErrorAction SilentlyContinue)) {. $PSScriptRoot\scripts\Get-Helpers.ps1}
        Get-ChocoEnvironmentProperty NuGetApiKey -AsPlainText
    ),

    # If provided, will skip launching the browser
    [switch]$SkipBrowserLaunch
)
process {
    $DefaultEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    Start-Transcript -Path "$env:SystemDrive\choco-setup\logs\Set-SslCertificate-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    # Collect current certificate configuration
    $Certificate = if ($Subject) {
        Get-Certificate -Subject $Subject
    }
    elseif ($Thumbprint) {
        Get-Certificate -Thumbprint $Thumbprint
    }

    if (-not $CertificateDnsName) {
        $matcher = 'CN\s?=\s?(?<Subject>[^,\s]+)'
        $null = $Certificate.Subject -match $matcher
        $SubjectWithoutCn = if ($Matches.Subject.StartsWith('*')) {
            # This is a wildcard cert, we need to prompt for the intended CertificateDnsName
            while ($CertificateDnsName -notlike $Matches.Subject) {
                $CertificateDnsName = Read-Host -Prompt "$(if ($CertificateDnsName) {"'$($CertificateDnsName)' is not a subdomain of '$($Matches.Subject)'. "})Please provide an FQDN to use with the certificate '$($Matches.Subject)'"
            }
            $CertificateDnsName
        }
        else {
            $Matches.Subject
        }
    }
    else {
        $SubjectWithoutCn = $CertificateDnsName
    }

    <# Nexus #>
    # Stop Services/Processes/Websites required
    Stop-Service nexus

    # Put certificate in TrustedPeople
    Copy-CertToStore -Certificate $Certificate

    # Generate Nexus keystore
    $null = Set-NexusCert -Thumbprint $Certificate.Thumbprint

    # Add firewall rule for Nexus
    netsh advfirewall firewall add rule name="Nexus-8443" dir=in action=allow protocol=tcp localport=8443
    
    Write-Verbose "Starting up Nexus"
    Start-Service nexus

    Write-Warning "Waiting to give Nexus time to start up on 'https://${SubjectWithoutCn}:8443'"
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::tls12
    do {
        $response = try {
            Invoke-WebRequest "https://${SubjectWithoutCn}:8443" -UseBasicParsing -ErrorAction Stop
            Start-Sleep -Seconds 3
        } catch {}
    } until($response.StatusCode -eq '200')
    Write-Host "Nexus is ready!"

    Invoke-Choco source remove --name="'ChocolateyInternal'"

    # Build Credential Object, Connect to Nexus
    $securePw = (Get-Content 'C:\programdata\sonatype-work\nexus3\admin.password') | ConvertTo-SecureString -AsPlainText -Force
    $Credential = [System.Management.Automation.PSCredential]::new('admin', $securePw)

    # Connect to Nexus
    Connect-NexusServer -Hostname $SubjectWithoutCn -Credential $Credential -UseSSL

    # Push ClientSetup.ps1 to raw repo
    $ClientScript = "$PSScriptRoot\scripts\ClientSetup.ps1"
    (Get-Content -Path $ClientScript) -replace "{{hostname}}", $SubjectWithoutCn | Set-Content -Path $ClientScript
    New-NexusRawComponent -RepositoryName 'choco-install' -File $ClientScript

    # Disable anonymous authentication
    Set-NexusAnonymousAuth -Disabled

    if (-not (Get-NexusRole -Role 'chocorole' -ErrorAction SilentlyContinue)) {
        # Create Nexus role
        $RoleParams = @{
            Id          = "chocorole"
            Name        = "chocorole"
            Description = "Role for web enabled choco clients"
            Privileges  = @('nx-repository-view-nuget-*-browse', 'nx-repository-view-nuget-*-read', 'nx-repository-view-raw-*-read', 'nx-repository-view-raw-*-browse')
        }
        New-NexusRole @RoleParams
    }

    if (-not (Get-NexusUser -User 'chocouser' -ErrorAction SilentlyContinue)) {
        $NexusPw = [System.Web.Security.Membership]::GeneratePassword(32, 12)
        # Create Nexus user
        $UserParams = @{
            Username     = 'chocouser'
            Password     = ($NexusPw | ConvertTo-SecureString -AsPlainText -Force)
            FirstName    = 'Choco'
            LastName     = 'User'
            EmailAddress = 'chocouser@example.com'
            Status       = 'Active'
            Roles        = 'chocorole'
        }
        New-NexusUser @UserParams
    }

    # Update all sources with credentials and the new path
    foreach ($Repository in Get-NexusRepository -Format nuget | Where-Object Type -eq 'hosted') {
        $RepositoryUrl = "https://${SubjectWithoutCn}:8443/repository/$($Repository.Name)/index.json"

        $ChocoArgs = @(
            'source',
            'add',
            "--name='$($Repository.Name)'",
            "--source='$RepositoryUrl'",
            '--priority=1',
            "--user='chocouser'",
            "--password='$NexusPw'"
        )
        & Invoke-Choco @ChocoArgs

        # Update Repository API key
        $chocoArgs = @('apikey', "--source='$RepositoryUrl'", "--api-key='$NuGetApiKey'")
        & Invoke-Choco @chocoArgs

        # Reset the NuGet v3 cache, such that it doesn't capture localhost as the FQDN
        Remove-NexusRepositoryFolder -RepositoryName $Repository.Name -Name v3
    }

    Update-Clixml -Properties @{
        NexusUri = "https://$($SubjectWithoutCn):8443"
        NexusRepo = "https://${SubjectWithoutCn}:8443/repository/ChocolateyInternal/index.json"
        ChocoUserPassword = $NexusPw
    }

    <# Jenkins #>
    $JenkinsHome = "C:\ProgramData\Jenkins\.jenkins"

    # Update Jenkins Jobs with Nexus URL
    Get-ChildItem -Path "$JenkinsHome\jobs" -Recurse -File -Filter 'config.xml' | Invoke-TextReplacementInFile -Replacement @{
        '(?<=https:\/\/)(?<HostName>.+)(?=:8443\/repository\/)' = $SubjectWithoutCn
    }

    # Generate Jenkins keystore
    Set-JenkinsCertificate -Thumbprint $Certificate.Thumbprint

    # Add firewall rule for Jenkins
    netsh advfirewall firewall add rule name="Jenkins-7443" dir=in action=allow protocol=tcp localport=7443

    Update-Clixml -Properties @{
        JenkinsUri = "https://$($SubjectWithoutCn):7443"
    }

    <# CCM #>
    # Update the service certificate
    Set-CcmCertificate -CertificateThumbprint $Certificate.Thumbprint
    
    # Remove old CCM web binding, and add new CCM web binding
    Stop-CcmService
    Remove-CcmBinding
    New-CcmBinding -Thumbprint $Certificate.Thumbprint
    Start-CcmService

    # Create the site hosting the certificate import script on port 80
    # Only run this if it's a self-signed cert which has 10-year validity
    if ($Certificate.NotAfter -gt (Get-Date).AddYears(5)) {
        $IsSelfSigned = $true
        .\scripts\New-IISCertificateHost.ps1
    }

    # Generate Register-C4bEndpoint.ps1
    $EndpointScript = "$PSScriptRoot\scripts\Register-C4bEndpoint.ps1"

    $ClientSaltValue = New-CCMSalt
    $ServiceSaltValue = New-CCMSalt
    $ScriptBlock = @"
`$ClientCommunicationSalt = '$ClientSaltValue'
`$ServiceCommunicationSalt = '$ServiceSaltValue'
`$FQDN = '$SubjectWithoutCN'
`$NexusUserPW = '$NexusPw'

# Touch NOTHING below this line
`$User = 'chocouser'
`$SecurePassword = `$NexusUserPW | ConvertTo-SecureString -AsPlainText -Force
`$RepositoryUrl = "https://`$(`$fqdn):8443/repository/ChocolateyInternal/index.json"

`$credential = [pscredential]::new(`$user, `$securePassword)

`$downloader = [System.Net.WebClient]::new()
`$downloader.Credentials = `$credential

`$script =  `$downloader.DownloadString("https://`$(`$FQDN):8443/repository/choco-install/ClientSetup.ps1")

`$params = @{
    Credential      = `$Credential
    ClientSalt      = `$ClientCommunicationSalt
    ServiceSalt      = `$ServiceCommunicationSalt
    InternetEnabled = `$true
    RepositoryUrl   = `$RepositoryUrl
}

& ([scriptblock]::Create(`$script)) @params
"@

    $ScriptBlock | Set-Content -Path $EndpointScript

    # Agent Setup
    $agentArgs = @{
        CentralManagementServiceUrl = "https://$($SubjectWithoutCn):24020/ChocolateyManagementService"
        ServiceSalt = $ServiceSaltValue
        ClientSalt = $ClientSaltValue
    }

    if (Test-SelfSignedCertificate -Certificate $Certificate) {
        # Register endpoint script
        (Get-Content -Path $EndpointScript) -replace "{{hostname}}", "'$SubjectWithoutCn'" | Set-Content -Path $EndpointScript
            $ScriptBlock = @"
`$downloader = New-Object -TypeName System.Net.WebClient
Invoke-Expression (`$downloader.DownloadString("http://`$(`$HostName):80/Import-ChocoServerCertificate.ps1"))
"@
        (Get-Content -Path $EndpointScript) -replace "# placeholder if using a self-signed cert", $ScriptBlock | Set-Content -Path $EndpointScript
    }

    Install-ChocolateyAgent @agentArgs

    Update-Clixml -Properties @{
        CCMWebPortal = "https://$($SubjectWithoutCn)/Account/Login"
        CCMServiceURL = "https://$($SubjectWithoutCn):24020/ChocolateyManagementService"
        CertSubject    = $SubjectWithoutCn
        CertThumbprint = $Certificate.Thumbprint
        CertExpiry     = $Certificate.NotAfter
        IsSelfSigned   = $IsSelfSigned
        ServiceSalt = ConvertTo-SecureString $ServiceSaltValue -AsPlainText -Force
        ClientSalt = ConvertTo-SecureString $ClientSaltValue -AsPlainText -Force
    }
}
end {
    Write-Host 'Writing README to Desktop; this file contains login information for all C4B services.'
    New-QuickstartReadme

    if (-not $SkipBrowserLaunch -and $Host.Name -eq 'ConsoleHost') {
        $Message = 'The CCM, Nexus & Jenkins sites will open in your browser in 10 seconds. Press any key to skip this.'
        $Timeout = New-TimeSpan -Seconds 10
        $Stopwatch = [System.Diagnostics.Stopwatch]::new()
        $Stopwatch.Start()
        Write-Host $Message -NoNewline -ForegroundColor Green
        do {
            # wait for a key to be available:
            if ([Console]::KeyAvailable) {
                # read the key, and consume it so it won't
                # be echoed to the console:
                $keyInfo = [Console]::ReadKey($true)
                Write-Host "`nSkipping the Opening of sites in your browser." -ForegroundColor Green
                # exit loop
                break
            }
            # write a dot and wait a second
            Write-Host '.' -NoNewline -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        while ($Stopwatch.Elapsed -lt $Timeout)
        $Stopwatch.Stop()

        if (-not ($keyInfo)) {
            Write-Host "`nOpening CCM, Nexus & Jenkins sites in your browser." -ForegroundColor Green
            $Readme = 'file:///C:/Users/Public/Desktop/README.html'
            $Ccm = "https://$($SubjectWithoutCn)/Account/Login"
            $Nexus = "https://$($SubjectWithoutCn):8443"
            $Jenkins = "https://$($SubjectWithoutCn):7443"
            try {
                Start-Process msedge.exe "$Readme", "$Ccm", "$Nexus", "$Jenkins"
            } catch {
                Start-Process chrome.exe "$Readme", "$Ccm", "$Nexus", "$Jenkins"
            }
        }
    }

    $ErrorActionPreference = $DefaultEap
    Stop-Transcript
}
