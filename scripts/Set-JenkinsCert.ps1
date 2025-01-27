<#
    .Synopsis
        Updates a keystore and ensure Jenkins is configured to use an appropriate port and certificate for HTTPS access

    .Example
        .\Set-JenkinsCert.ps1 -Thumbprint $Thumbprint -Port 7443

    .Notes
        Restarts the Jenkins service if it is running.
#>
param(
    # Thumbprint of the certificate stored in the Trusted People cert-store.
    [Parameter(Mandatory)]
    [Alias("CertificateThumbprint")]
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
    [String]
    $Thumbprint,

    # Port number to use for Jenkins HTTPS.
    [uint16]$Port = 7443
)

. $PSScriptRoot\Get-Helpers.ps1
Set-JenkinsCertificate @PSBoundParameters