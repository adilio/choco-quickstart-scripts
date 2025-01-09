<#
.SYNOPSIS
C4B Quick-Start Guide initial bootstrap script

.DESCRIPTION
- Performs the following C4B Server initial bootstrapping
    - Install of Chocolatey
    - Prompt for C4B license, with validation
    - Script to help turn your C4B license into a Chocolatey package
    - Setup of local `choco-setup` directories
    - Download of Chocolatey packages required for setup
#>
[CmdletBinding(DefaultParameterSetName="Attended")]
param(
    # Full path to Chocolatey license file.
    # Accepts any file, and moves and renames it correctly.
    # You can either define this as a parameter, or
    # script will prompt you for it.
    # Script will also validate expiry.
    [Parameter(ParameterSetName='Unattended')]
    [Parameter(ParameterSetName='Attended')]
    [string]
    $LicenseFile = $(
        if (Test-Path $PSScriptRoot\files\chocolatey.license.xml) {
            # Offline setup has been run, we should use that license.
            Join-Path $PSScriptRoot "files\chocolatey.license.xml"
        } elseif (Test-Path $env:ChocolateyInstall\license\chocolatey.license.xml) {
            # Chocolatey is already installed, we can use that license.
            Join-Path $env:ChocolateyInstall "license\chocolatey.license.xml"
        } else {
            # Prompt the user for the license.
            $Wshell = New-Object -ComObject Wscript.Shell
            $null = $Wshell.Popup('You will need to provide the license file location. Please select your Chocolatey License in the next file dialog.')
            $null = [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms")
            $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
            $OpenFileDialog.initialDirectory = "$env:USERPROFILE\Downloads"
            $OpenFileDialog.filter = 'All Files (*.*)| *.*'
            $null = $OpenFileDialog.ShowDialog()

            $OpenFileDialog.filename
        }
    ),

    # Unattended mode. Allows you to skip running the other scripts indiviually.
    [Parameter(Mandatory, ParameterSetName='Unattended')]
    [switch]
    $Unattend,

    # Specify a credential used for the ChocolateyManagement DB user.
    # Only required in Unattend mode for the CCM setup script.
    # If not populated, the script will prompt for credentials.
    [Parameter(ParameterSetName='Unattended')]
    [System.Management.Automation.PSCredential]
    $DatabaseCredential = $(
        if ($PSCmdlet.ParameterSetName -eq 'Unattended') {
            $Wshell = New-Object -ComObject Wscript.Shell
            $null = $Wshell.Popup('You will now create a credential for the ChocolateyManagement DB user, to be used by CCM (document this somewhere).')
            Get-Credential -UserName ChocoUser -Message 'Create a credential for the ChocolateyManagement DB user'
        }
    ),

    # The certificate thumbprint that identifies the target SSL certificate in
    # the local machine certificate stores.
    # Only used in Unattend mode for the SSL setup script.
    [Parameter(ParameterSetName='Unattended')]
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
    $Thumbprint,

    # If provided, shows all Chocolatey output. Otherwise, blissful quiet.
    [switch]$ShowChocoOutput,

    # The branch or Pull Request to download the C4B setup scripts from.
    # Defaults to main.
    [string]
    [Alias('PR')]
    $Branch = $env:CHOCO_QSG_BRANCH
)
if ($ShowChocoOutput) {
    $global:PSDefaultParameterValues["Invoke-Choco:InformationAction"] = "Continue"
}

$QsRepo = if ($Branch) {
    if ((Invoke-RestMethod -Uri "https://api.github.com/repos/chocolatey/choco-quickstart-scripts/branches").name -contains $Branch) {
        "https://api.github.com/repos/chocolatey/choco-quickstart-scripts/zipball/$Branch"
    } elseif ($PullRequest = Invoke-RestMethod -Uri "https://api.github.com/repos/chocolatey/choco-quickstart-scripts/pulls/$Branch" -ErrorAction SilentlyContinue) {
        $PullRequest.head.repo.archive_url -replace '{archive_format}', 'zipball' -replace '{/ref}', "/$($PullRequest.head.ref)"
    } else {
        Write-Error "'$($Branch)' is not a valid branch or pull request number. Please provide a valid branch or pull request number."
    }
} else {
    "https://api.github.com/repos/chocolatey/choco-quickstart-scripts/zipball/main"
}

$DefaultEap, $ErrorActionPreference = $ErrorActionPreference, 'Stop'
Start-Transcript -Path "$env:SystemDrive\choco-setup\logs\Start-C4bSetup-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

try {
    # Setup initial choco-setup directories
    Write-Host "Setting up initial directories in"$env:SystemDrive\choco-setup"" -ForegroundColor Green
    $ChocoPath = "$env:SystemDrive\choco-setup"
    $FilesDir = Join-Path $ChocoPath "files"
    $PkgsDir = Join-Path $FilesDir "files"
    $TempDir = Join-Path $ChocoPath "temp"
    $TestDir = Join-Path $ChocoPath "tests"
    $xmlDir = Join-Path $ChocoPath "clixml"

    @($ChocoPath, $FilesDir, $PkgsDir, $TempDir, $TestDir,$xmlDir) | ForEach-Object {
        $null = New-Item -Path $_ -ItemType Directory -Force -ErrorAction Stop
    }

    if (-not $PSScriptRoot -or $PSScriptRoot -ne $FilesDir) {
        # Download and extract C4B setup files from repo
        try {
            Invoke-WebRequest -Uri $QsRepo -UseBasicParsing -OutFile "$TempDir\choco-quickstart-scripts.zip"
            Expand-Archive "$TempDir\choco-quickstart-scripts.zip" $TempDir
            Copy-Item "$TempDir\*\*" $FilesDir -Recurse -Force
        } finally {
            Remove-Item "$TempDir" -Recurse -Force
        }
    }

    # Add the Module Path and Import Helper Functions
    if (-not (Get-Module C4B-Environment -ListAvailable)) {
        if ($env:PSModulePath.Split(';') -notcontains "$FilesDir\modules") {
            [Environment]::SetEnvironmentVariable("PSModulePath", "$env:PSModulePath;$FilesDir\modules" ,"Machine")
            $env:PSModulePath = [Environment]::GetEnvironmentVariables("Machine").PSModulePath
        }
    }
    Import-Module C4B-Environment -Verbose:$false

    # Downloading all CCM setup packages below
    Write-Host "Downloading missing nupkg files to $($PkgsDir)." -ForegroundColor Green
    Write-Host "This will take some time. Feel free to get a tea or coffee." -ForegroundColor Green

    & $FilesDir\OfflineInstallPreparation.ps1 -LicensePath $LicenseFile

    if (Test-Path $FilesDir\files\*.nupkg) {
        Invoke-Choco source add --name LocalChocolateySetup --source $FilesDir\files\ --Priority 1
    }

    # Set Choco Server Chocolatey Configuration
    Invoke-Choco feature enable --name="'excludeChocolateyPackagesDuringUpgradeAll'"
    Invoke-Choco feature enable --name="'usePackageHashValidation'"

    # Convert license to a "choco-license" package, and install it locally to test
    Write-Host "Creating a 'chocolatey-license' package, and testing install." -ForegroundColor Green
    Set-Location $FilesDir
    .\scripts\Create-ChocoLicensePkg.ps1
    Remove-Item "$env:SystemDrive\choco-setup\packaging" -Recurse -Force

    # Kick off unattended running of remaining setup scripts.
    if ($Unattend) {
        $Certificate = @{}
        if ($Thumbprint) {$Certificate.Thumbprint = $Thumbprint}

        Set-Location "$env:SystemDrive\choco-setup\files"
        .\Start-C4BNexusSetup.ps1
        .\Start-C4bCcmSetup.ps1 @Certificate -DatabaseCredential $DatabaseCredential
        .\Start-C4bJenkinsSetup.ps1
        .\Set-SslSecurity.ps1 @Certificate
    }
} finally {
    $ErrorActionPreference = $DefaultEap
    Stop-Transcript
}