<#
.SYNOPSIS
Certificate renewal script for Nexus.

.DESCRIPTION
Helps edit the java keystore file for Nexus when doing a certificate renewal.

.PARAMETER Thumbprint
Thumbprint value of certificate you want to run Nexus on. Make sure certificate is located at Cert:\LocalMachine\TrustedPeople\

.PARAMETER NexusPort
Port you have Nexus configured to run on.

.EXAMPLE
PS> .\Set-NexusCert.ps1 -Thumbprint 'Your_Certificate_Thumbprint_Value' -NexusPort 'Port_Number'
#>

[CmdletBinding()]
param(
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

    [Parameter()]
    [string]
    $NexusPort = '8443'
)

begin {
    if($host.name -ne 'ConsoleHost') {
        Write-Warning "This script cannot be ran from within PowerShell ISE"
        Write-Warning "Please launch powershell.exe as an administrator, and run this script again"
        break
    }
}

process {

$ErrorActionPreference = 'Stop'

if ((Test-Path C:\ProgramData\nexus\etc\ssl\keystore.jks)) {
    Remove-Item C:\ProgramData\nexus\etc\ssl\keystore.jks -Force
}

$KeyTool = "C:\ProgramData\nexus\jre\bin\keytool.exe"
$password = "chocolatey" | ConvertTo-SecureString -AsPlainText -Force
$certificate = Get-ChildItem  Cert:\LocalMachine\TrustedPeople\ | Where-Object { $_.Thumbprint -eq $Thumbprint } | Sort-Object | Select-Object -First 1

Write-Host "Exporting .pfx file to C:\, will remove when finished" -ForegroundColor Green
$certificate | Export-PfxCertificate -FilePath C:\cert.pfx -Password $password
Get-ChildItem -Path c:\cert.pfx | Import-PfxCertificate -CertStoreLocation Cert:\LocalMachine\My -Exportable -Password $password
Write-Warning -Message "You'll now see prompts and other outputs, things are working as expected, don't do anything"
$string = ("chocolatey" | & $KeyTool -list -v -keystore C:\cert.pfx -J"-Duser.language=en") -match '^Alias.*'
$currentAlias = ($string -split ':')[1].Trim()

$passkey = '9hPRGDmfYE3bGyBZCer6AUsh4RTZXbkw'
& $KeyTool -importkeystore -srckeystore C:\cert.pfx -srcstoretype PKCS12 -srcstorepass chocolatey -destkeystore C:\ProgramData\nexus\etc\ssl\keystore.jks -deststoretype JKS -alias $currentAlias -destalias jetty -deststorepass $passkey
& $KeyTool -keypasswd -keystore C:\ProgramData\nexus\etc\ssl\keystore.jks -alias jetty -storepass $passkey -keypass chocolatey -new $passkey

$xmlPath = 'C:\ProgramData\nexus\etc\jetty\jetty-https.xml'
[xml]$xml = Get-Content -Path 'C:\ProgramData\nexus\etc\jetty\jetty-https.xml'
foreach ($entry in $xml.Configure.New.Where{ $_.id -match 'ssl' }.Set.Where{ $_.name -match 'password' }) {
    $entry.InnerText = $passkey
}

$xml.OuterXml | Set-Content -Path $xmlPath

Remove-Item C:\cert.pfx

$nexusPath = 'C:\ProgramData\sonatype-work\nexus3'
$configPath = "$nexusPath\etc\nexus.properties"

(Get-Content $configPath) | Where-Object {$_ -notmatch "application-port-ssl="} | Set-Content $configPath

$configStrings = @('jetty.https.stsMaxAge=-1', "application-port-ssl=$NexusPort", 'nexus-args=${jetty.etc}/jetty.xml,${jetty.etc}/jetty-https.xml,${jetty.etc}/jetty-requestlog.xml')
$configStrings | ForEach-Object {
    if ((Get-Content -Raw $configPath) -notmatch [regex]::Escape($_)) {
        $_ | Add-Content -Path $configPath
    }
}

Restart-Service nexus

Write-Host -BackgroundColor Black -ForegroundColor DarkGreen "The script has successfully run and the Nexus service is now rebooting for the changes to take effect."
}