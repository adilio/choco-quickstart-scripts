<#
.SYNOPSIS
Creates the `ChocolateyInstall` IIS fileshare site.

.DESCRIPTION
Creates a new IIS website named `ChocolateyInstall` which hosts the
Import-ChocoServerCertificate.ps1 for clients to retrieve and run during their
setup.

If you have a need to re-create this for any reason, ensure the existing
`ChocolateyInstall` IIS site has been disabled and removed.
#>
[CmdletBinding()]
param(
    # The path to a local directory which will be used to host the
    # Import-ChocoServerCertificate.ps1 file over IIS for clients to utilize.
    [Parameter()]
    [Alias('LocalDir')]
    [string]
    $Path = 'C:\tools\ChocolateyInstall'
)

Import-Module WebAdministration

$hostName = [System.Net.Dns]::GetHostName()
$domainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName

if (-not $hostName.endswith($domainName)) {
    $hostName += "." + $domainName
}

if (-not (Test-Path $Path)) {
    $null = New-Item -Path $Path -ItemType Directory -Force
}

$ImportScript = Join-Path $Path "Import-ChocoServerCertificate.ps1"
if (-not (Test-Path $ImportScript)) {
    Copy-Item -Path "$PSScriptRoot/Import-ChocoServerCertificate.ps1" -Destination $Path
}
(Get-Content -Path $ImportScript) -replace "{{hostname}}", $HostName | Set-Content -Path $ImportScript


$siteName = 'C4bSslCertificateImport'
if (-not (Get-Website -Name $siteName)) {
    Write-Host "Creating Website: $siteName" -ForegroundColor Green
    $null = New-Website -Name $siteName -Port 80 -PhysicalPath $Path -Force
    Add-WebConfigurationProperty -PSPath IIS: -Filter system.webServer/staticContent -Name "." -Value @{ fileExtension = '.ps1'; mimeType = 'text/plain' }
} else {
    Write-Host "Website for hosting certificate import already created" -ForegroundColor Green
}

Write-Host "Restarting IIS to refresh bindings" -ForegroundColor Green
$null = iisreset

if ((Get-Website -Name $siteName).State -ne 'Started') {
    Start-Website -Name $siteName
}

if ((Get-Website -Name 'Default Web Site')) {
    Get-Website -Name 'Default Web Site' | Remove-Website
} else {
    Write-Host "Default website already removed" -ForegroundColor Green
}

Write-Host "IIS website started on port 80 hosting Import-ChocoServerCertificate.ps1 from $Path"
