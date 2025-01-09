<#
.SYNOPSIS
Completes client setup for a client machine to communicate with the C4B Server.
#>
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    # The URL of the the internal Nexus repository to install Chocolatey from.
    # This URL will be used to create the internal package source configuration.
    [Parameter()]
    [Alias('Url')]
    [string]
    $RepositoryUrl = 'https://{{hostname}}:8443/repository/ChocolateyInternal/index.json',

    # The credential necessary to access the internal Nexus repository. This can
    # be ignored if Anonymous authentication is enabled.
    # This parameter will be necessary if your C4B server is web-enabled.
    [Parameter(Mandatory)]
    [pscredential]
    $RepositoryCredential,

    # Specifies a target version of Chocolatey to install. By default, the
    # latest stable version is installed.
    [Parameter()]
    [string]
    $ChocolateyVersion = $env:chocolateyVersion,

    # Specifies whether to ignore any configured proxy. This will override any
    # specified proxy environment variables.
    [Parameter()]
    [switch]
    $IgnoreProxy = [bool]$env:chocolateyIgnoreProxy,

    # The URL of a proxy server to use for connecting to the repository.
    [Parameter(Mandatory = $true, ParameterSetName = 'Proxy')]
    $ProxyUrl = $env:chocolateyProxyLocation,

    # The credentials, if required, to connect to the proxy server.
    [Parameter(ParameterSetName = 'Proxy')]
    [pscredential]
    $ProxyCredential,

    # Client salt value used to populate the centralManagementClientCommunicationSaltAdditivePassword
    # value in the Chocolatey config file
    [Parameter()]
    [string]
    $ClientCommunicationSalt,

    # Server salt value used to populate the centralManagementServiceCommunicationSaltAdditivePassword
    # value in the Chocolatey config file
    [Parameter()]
    [string]
    $ServiceCommunicationSalt,

    #Install the Chocolatey Licensed Extension with right-click context menus available
    [Parameter()]
    [Switch]
    $IncludePackageTools,

    # Allows for the application of user-defined configuration that is applied after the base configuration.
    # Can override base configuration with this parameter
    [Parameter()]
    [Hashtable]
    $AdditionalConfiguration,

    # Allows for the toggling of additonal features that is applied after the base configuration.
    # Can override base configuration with this parameter
    [Parameter()]
    [Hashtable]
    $AdditionalFeatures,

    # Allows for the installation of additional packages after the system base packages have been installed.
    [Parameter()]
    [Hashtable[]]
    $AdditionalPackages,

    # Allows for the addition of alternative sources after the base conifguration  has been applied.
    # Can override base configuration with this parameter
    [Parameter()]
    [Hashtable[]]
    $AdditionalSources
)

Set-ExecutionPolicy Bypass -Scope Process -Force

$hostAddress = $RepositoryUrl.Split('/')[2]
$hostName = ($hostAddress -split ':')[0]

$params = @{
    ChocolateyVersion = $ChocolateyVersion
    IgnoreProxy       = $IgnoreProxy
    UseNativeUnzip    = $true
}

if (-not $IgnoreProxy) {
    if ($ProxyUrl) {
        $proxy = [System.Net.WebProxy]::new($ProxyUrl, $true <#bypass on local#>)
        $params.Add('ProxyUrl', $ProxyUrl)
    }

    if ($ProxyCredential) {
        $params.Add('ProxyCredential', $ProxyCredential)
        $proxy.Credentials = $ProxyCredential
        
    }
}

$webClient = New-Object System.Net.WebClient
if ($RepositoryCredential) {
    $webClient.Credentials = $RepositoryCredential.GetNetworkCredential()
}

# Find the latest version of Chocolatey, if a version was not specified
$NupkgUrl = if (-not $ChocolateyVersion) {
    $QueryUrl = (($RepositoryUrl -replace '/index\.json$'), "v3/registration/Chocolatey/index.json") -join '/'
    $Result = $webClient.DownloadString($QueryUrl) | ConvertFrom-Json
    $Result.items.items[-1].packageContent
}
else {
    # Otherwise, assume the URL
    "$($RepositoryUrl -replace '/index\.json$')/v3/content/chocolatey/$($ChocolateyVersion)/chocolatey.$($ChocolateyVersion).nupkg"
}

# Download the NUPKG
$NupkgPath = Join-Path $env:TEMP "$(New-Guid).zip"
$webClient.DownloadFile($NupkgUrl, $NupkgPath)

# Add Parameter for ChocolateyDownloadUrl, that is the NUPKG path
$params.Add('ChocolateyDownloadUrl', $NupkgPath)

# Get the script content
$script = $webClient.DownloadString("https://${hostAddress}/repository/choco-install/ChocolateyInstall.ps1")

# Run the Chocolatey Install script with the parameters provided
& ([scriptblock]::Create($script)) @params

# If FIPS is enabled, configure Chocolatey to use FIPS compliant checksums
$fipsStatus = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy" -Name Enabled
if ($fipsStatus.Enabled -eq 1) {
    Write-Warning -Message "FIPS is enabled on this system. Ensuring Chocolatey uses FIPS compliant checksums"
    choco feature enable --name='useFipsCompliantChecksums'
}

choco config set cacheLocation $env:ChocolateyInstall\choco-cache
choco config set commandExecutionTimeoutSeconds 14400

# Nexus NuGet V3 Compatibility
choco feature disable --name="'usePackageRepositoryOptimizations'"

# Environment base Source configuration
choco source add --name="'ChocolateyInternal'" --source="'$RepositoryUrl'" --allow-self-service --user="'$($RepositoryCredential.UserName)'" --password="'$($RepositoryCredential.GetNetworkCredential().Password)'" --priority=1
choco source disable --name="'Chocolatey'"
choco source disable --name="'chocolatey.licensed'"

choco upgrade chocolatey-license -y --source="'ChocolateyInternal'"
if (-not $IncludePackageTools) {
    choco upgrade chocolatey.extension -y --params="'/NoContextMenu'" --source="'ChocolateyInternal'" --no-progress
} 
else {
    Write-Warning "IncludePackageTools was passed. Right-Click context menus will be available for installers, .nupkg, and .nuspec file types!"
    choco upgrade chocolatey.extension -y --source="'ChocolateyInternal'" --no-progress
}
choco upgrade chocolateygui -y --source="'ChocolateyInternal'" --no-progress
choco upgrade chocolateygui.extension -y --source="'ChocolateyInternal'" --no-progress

choco upgrade chocolatey-agent -y --source="'ChocolateyInternal'"

# Chocolatey Package Upgrade Resilience
choco feature enable --name="'excludeChocolateyPackagesDuringUpgradeAll'"

# Self-Service configuration
choco feature disable --name="'showNonElevatedWarnings'"
choco feature enable --name="'useBackgroundService'"
choco feature enable --name="'useBackgroundServiceWithNonAdministratorsOnly'"
choco feature enable --name="'allowBackgroundServiceUninstallsFromUserInstallsOnly'"
choco config set --name="'backgroundServiceAllowedCommands'" --value="'install,upgrade,uninstall'"

# Enable Package Hash Validation (Good security practice)
choco feature enable --name="'usePackageHashValidation'"

# CCM Check-in Configuration
choco config set CentralManagementServiceUrl "https://${hostName}:24020/ChocolateyManagementService"
if ($ClientCommunicationSalt) {
    choco config set centralManagementClientCommunicationSaltAdditivePassword $ClientCommunicationSalt
}
if ($ServiceCommunicationSalt) {
    choco config set centralManagementServiceCommunicationSaltAdditivePassword $ServiceCommunicationSalt
}
choco feature enable --name="'useChocolateyCentralManagement'"
choco feature enable --name="'useChocolateyCentralManagementDeployments'"


if ($AdditionalConfiguration -or $AdditionalFeatures -or $AdditionalSources -or $AdditionalPackages) {
    Write-Host "Applying user supplied configuration" -ForegroundColor Cyan
}
# How we call choco from here changes as we need to be more dynamic with thingsii .
if ($AdditionalConfiguration) {
    <#
    We expect to pass in a hashtable with configuration information with the following shape:

    @{
        Name = BackgroundServiceAllowedCommands 
        Value = 'install,upgrade,uninstall'
    }
    #>

    $AdditionalConfiguration.GetEnumerator() | ForEach-Object {
        $Config = [System.Collections.Generic.list[string]]::new()
        $Config.Add('config')
        $Config.Add('set')
        $Config.Add("--name='$($_.Key)'")
        $Config.Add("--value='$($_.Value)'")

        & choco @Config
    }
}

if ($AdditionalFeatures) {
    <#
    We expect to pass in feature information as a hashtable with the following shape:

    @{
        useBackgroundservice = 'Enabled'
    }
    #>
   $AdditionalFeatures.GetEnumerator() | ForEach-Object {

        $Feature = [System.Collections.Generic.list[string]]::new()
        $Feature.Add('feature')

        $state = switch ($_.Value) {
            'Enabled' { 'enable' }
            'Disabled' { 'disable' }
            default { Write-Error 'State must be either Enabled or Disabled' }
        }

        $Feature.Add($state)
        $Feature.add("--name='$($_.Key)'")
        & choco @Feature
    }
}

if ($AdditionalSources) {

    <#
    We expect a user to pass in a hashtable with source information with the folllowing shape:
    @{
        Name = 'MySource'
        Source = 'https://nexus.fabrikam.com/repository/MyChocolateySource'
        #Optional items
        Credentials = $MySourceCredential
        AllowSelfService = $true
        AdminOnly = $true
        BypassProxy = $true
        Priority = 10
        Certificate = 'C:\cert.pfx'
        CertificatePassword = 's0mepa$$'
    }
#>
    Foreach ($Source in $AdditionalSources) {
        $SourceSplat = [System.Collections.Generic.List[string]]::new()
        # Required items
        $SourceSplat.Add('source')
        $SourceSplat.Add('add')
        $SourceSplat.Add("--name='$($Source.Name)'")
        $SourceSplat.Add("--source='$($Source.Source)'")

        # Add credentials if source has them
        if ($Source.ContainsKey('Credentials')) {
            $SourceSplat.Add("--user='$($Source.Credentials.Username)'")
            $SourceSplat.Add("--password='$($Source.Credentials.GetNetworkCredential().Password)'")
        }

        switch ($true) {
            $Source['AllowSelfService'] { $SourceSplat.add('--allow-self-service') }
            $Source['AdminOnly'] { $SourceSplat.Add('--admin-only') }
            $Source['BypassProxy'] { $SourceSplat.Add('--bypass-proxy') }
            $Source.ContainsKey('Priority') { $SourceSplat.Add("--priority='$($Source.Priority)'") }
            $Source.ContainsKey('Certificate') { $SourceSplat.Add("--cert='$($Source.Certificate)'") }
            $Source.ContainsKey('CerfificatePassword') { $SourceSplat.Add("--certpassword='$($Source.CertificatePassword)'") }
        }
    }

    & choco @SourceSplat
}

if ($AdditionalPackages) {

    <#
    We expect to pass in a hashtable with package information with the following shape:

    @{
        Id = 'firefox'
        #Optional
        Version = 123.4.56
        Pin = $true
    }
    #>
    foreach ($package in $AdditionalPackages.GetEnumerator()) {
        
        $PackageSplat = [System.Collections.Generic.list[string]]::new()
        $PackageSplat.add('install')
        $PackageSplat.add($package['Id'])

        switch ($true) {
            $package.ContainsKey('Version') { $PackageSplat.Add("--version='$($package.version)'") }
            $package.ContainsKey('Pin') { $PackageSplat.Add('--pin') }
        }

        # Ensure packages install and they don't flood the console output
        $PackageSplat.Add('-y')
        $PackageSplat.Add('--no-progress')

        & choco @PackageSplat
    }
}