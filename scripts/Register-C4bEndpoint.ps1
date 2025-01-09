<#
    .SYNOPSIS
    Deploys Chocolatey onto an endpoint.

    .EXAMPLE

    Some endpoints may require a different set of features. The default installation will apply our _recommended_ configuration.
    However, you can override these defaults or enable/disable additional features by providing the `-AdditionalFeatures` parameter.

    In this example we will disable the use of the background service so non-admin users cannot use Chocolatey (not recommended), and enable Gloabl Confirmation so you no longer need to pass -y when performing a package operation.
    
    . .\Register-C4bEndpoint.ps1 -RepositoryCredential (Get-Credential) -AdditionalFeatures @{ useBackgroundService = 'Disabled'; allowGlobalCOnfirmation = 'Enabled' }
    
    .EXAMPLE
    You can apply custom configuration which overrides the defaults or provides additional configuration by providing the `-AdditionalConfiguration` parameter.
    The following example sets the `centralManagementReportPackagesTimerIntervalInSeconds` configuration item to 21600 seconds (6 hours).

    . .\Register-C4bEndpoint.ps1 -RepositoryCredential (Get-Credential) -AdditionalConfiguration @{ 'centralManagementReportPackagesTimerIntervalInSeconds' = '21600'}

    .EXAMPLE
    You can include additional Chocolatey sources during the installation process by providing the `-AdditionalSources` parameter.

    . .\Register-C4bEndpoint.ps1 -RepositoryCredential (Get-Credential) -AdditionalSources @{Name = 'ChocolateyUpstream'; Source = 'https://community.chocolatey.org/api/v2/'}

    .EXAMPLE
    This example include Packaging Tools and sets up a local folder source for package development testing.
    The local folder must exist prior to using this source.

    . .\Register-C4bEndpoint.ps1 -RepositoryCredential (Get-Credential) -AdditionalSources @{Name = 'LocalTest'; Source = 'C:\packages\testing'}


    .EXAMPLE
    The following example installs the notepadplusplus.install package.

    . .\Register-C4bEndpoint.ps1 -RepositoryCredential (Get-Credential) -AdditionalPackages @{Id ='notepadplusplus.install'}

    .EXAMPLE
    The following example installs version 8.7.5 of the notepadplusplus.install package.
    
    . .\Register-C4bEndpoint.ps1 -RepositoryCredential (Get-Credential) -AdditionalPackages @{Id ='notepadplusplus.install'; Version = '8.7.5'}
    
    .EXAMPLE
    The following example installs version 8.7.5 of the notepadplusplus.install package and pins it so that it is not upgraded when using `choco upgrade`
    To upgrade this package, you will need to first unpin it, and then perform the upgrade.
   
    . .\Register-C4bEndpoint.ps1 -RepositoryCredential (Get-Credential) -AdditionalPackages @{Id ='notepadplusplus.install'; Version = '8.7.5'; Pin = $true}
    
    .NOTES

    Full documentation is available at https://docs.chocolatey.org/en-us/c4b-environments/quick-start-environment/advanced-client-configuration/
    #>
[CmdletBinding(HelpUri = 'https://docs.chocolatey.org/en-us/c4b-environments/quick-start-environment/advanced-client-configuration/')]
Param(
    # The DNS name of the server that hosts your repository, Jenkins, and Chocolatey Central Management
    [Parameter()]
    [String]
    $Fqdn = '{{ FQDN }}',

    # Client salt value used to populate the centralManagementClientCommunicationSaltAdditivePassword
    # value in the Chocolatey config file
    [Parameter()]
    [String]
    $ClientCommunicationSalt = '{{ ClientSaltValue }}',

    # Server salt value used to populate the centralManagementServiceCommunicationSaltAdditivePassword
    # value in the Chocolatey config file
    [Parameter()]
    [String]
    $ServiceCommunicationSalt = '{{ ServiceSaltValue }}',

    [Parameter(Mandatory)]
    [PSCredential]
    $RepositoryCredential,

    # The URL of a proxy server to use for connecting to the repository.
    [Parameter()]
    [String]
    $ProxyUrl,
    # The credentials, if required, to connect to the proxy server.
    [Parameter()]
    [PSCredential]
    $ProxyCredential,

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
    $AdditionalSources,

    # If passed, downloads the certificate from the client server before initializing Chocolatey Agent
    [Parameter()]
    [Switch]
    $TrustCertificate
)

# Touch NOTHING below this line
begin {
    
    $params = $PSCmdlet.MyInvocation.BoundParameters

    $commonParameters = @(
        'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
        'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
    
    $PSCmdlet.MyInvocation.MyCommand.Parameters.Keys | ForEach-Object {
        if ((-not $params.ContainsKey($_)) -and ($_ -notin $commonParameters)) {
            $params[$_] = (Get-Variable -Name $_ -Scope 0 -ErrorAction SilentlyContinue).Value
        }
    }
    # Set up our downloader
    $downloader = [System.Net.WebClient]::new()

    # Setup proxy if required
    if ($ProxyUrl) {
        $proxy = [System.Net.WebProxy]::new($ProxyUrl, $true <#bypass on local#>)
   
        if ($ProxyCredential) {
            $proxy.Credentials = $ProxyCredential
        }

        $downloader.Proxy = $proxy
    }

    $downloader.Credentials = $RepositoryCredential

}

end {
    # If we use a Self-Signed certificate, we need to explicity trust it
    if ($TrustCertificate) {
        Invoke-Expression ($downloader.DownloadString("http://$($Fqdn):80/Import-ChocoServerCertificate.ps1"))
    }

    # Once we trust the SSL certificate, we can start onboarding
    $RepositoryUrl = "https://$($fqdn):8443/repository/ChocolateyInternal/index.json"

    foreach ($Parameter in @("FQDN", "TrustCertificate")) {
        $null = $params.Remove($Parameter)
    }

    $params += @{
        RepositoryUrl = $RepositoryUrl
    }

    $script = $downloader.DownloadString("https://$($FQDN):8443/repository/choco-install/ClientSetup.ps1")

    & ([scriptblock]::Create($script)) @params
}