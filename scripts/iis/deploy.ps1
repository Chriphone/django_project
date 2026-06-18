param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactPath,

    [Parameter(Mandatory = $true)]
    [string]$ReleaseId,

    [Parameter(Mandatory = $true)]
    [string]$SiteName,

    [Parameter(Mandatory = $true)]
    [string]$AppPoolName,

    [Parameter(Mandatory = $true)]
    [string]$DeployRoot,

    [Parameter(Mandatory = $true)]
    [string]$HostHeader,

    [int]$HttpPort = 80,

    [string]$ConfigPath = "C:\Deploy\KVTC\.env",

    [int]$KeepReleases = 5
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-WindowsFeature {
    param([string[]]$Names)

    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        $serverNames = $Names | Where-Object { $_ -like "Web-*" }
        $missing = Get-WindowsFeature -Name $serverNames | Where-Object { -not $_.Installed }
        if ($missing) {
            Install-WindowsFeature -Name ($missing.Name) -IncludeManagementTools | Out-Null
        }
        return
    }

    foreach ($name in ($Names | Where-Object { $_ -like "IIS-*" })) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
        if ($feature -and $feature.State -ne "Enabled") {
            Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart | Out-Null
        }
    }
}

function Find-Python312 {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $path = (& py -3.12 -c "import sys; print(sys.executable)" 2>$null)
        if ($LASTEXITCODE -eq 0 -and $path) {
            return $path.Trim()
        }
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles "Python312\python.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Python312\python.exe"),
        (Join-Path $env:LocalAppData "Programs\Python\Python312\python.exe")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            $version = (& $candidate -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $version.Trim() -eq "3.12") {
                return $candidate
            }
        }
    }

    return $null
}

function Get-Python312 {
    $path = Find-Python312
    if ($path) {
        return $path
    }

    if (Get-Command py -ErrorAction SilentlyContinue) {
        Write-Step "Python 3.12 not found through py; attempting py install"
        & py install -y 3.12 | Write-Host
        $path = Find-Python312
        if ($path) {
            return $path
        }
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Step "Python 3.12 not found; attempting winget install"
        & winget install --id Python.Python.3.12 -e --silent --accept-source-agreements --accept-package-agreements | Write-Host
        $path = Find-Python312
        if ($path) {
            return $path
        }
    }

    Write-Step "Python 3.12 not found; attempting python.org installer"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $installer = Join-Path $env:TEMP "python-3.12.10-amd64.exe"
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe" -OutFile $installer -UseBasicParsing
    $process = Start-Process -FilePath $installer -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_launcher=1 Include_pip=1" -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Python installer failed with exit code $($process.ExitCode)."
    }

    $path = Find-Python312
    if ($path) {
        return $path
    }

    throw "Python 3.12 is required and could not be installed automatically. Install Python 3.12 or Python Install Manager, then rerun."
}

function Read-EnvFile {
    param([string]$Path)

    $values = @{}
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
        @(
            "DATABASE_URL=mysql://root@127.0.0.1:3306/KTVTC",
            "DJANGO_DEBUG=True",
            "DJANGO_ALLOWED_HOSTS=$HostHeader,localhost,127.0.0.1",
            "DJANGO_CSRF_TRUSTED_ORIGINS=http://$HostHeader,https://$HostHeader",
            "EMAIL_ADDRESS=",
            "EMAIL_PASSWORD="
        ) | Set-Content -LiteralPath $Path -Encoding UTF8
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) {
            continue
        }

        $parts = $trimmed.Split("=", 2)
        $key = $parts[0].Trim().TrimStart([char]0xFEFF)
        $values[$key] = $parts[1].Trim()
    }

    if (-not $values.ContainsKey("DJANGO_DEBUG")) {
        $values["DJANGO_DEBUG"] = "True"
    }
    if (-not $values.ContainsKey("DJANGO_ALLOWED_HOSTS")) {
        $values["DJANGO_ALLOWED_HOSTS"] = "$HostHeader,localhost,127.0.0.1"
    }
    if (-not $values.ContainsKey("DJANGO_CSRF_TRUSTED_ORIGINS")) {
        $values["DJANGO_CSRF_TRUSTED_ORIGINS"] = "http://$HostHeader,https://$HostHeader"
    }
    if (-not $values.ContainsKey("DATABASE_URL")) {
        $values["DATABASE_URL"] = "mysql://root@127.0.0.1:3306/KTVTC"
    }

    return $values
}

function Set-ProcessEnv {
    param([hashtable]$Values)

    foreach ($key in $Values.Keys) {
        [Environment]::SetEnvironmentVariable($key, [string]$Values[$key], "Process")
    }
}

function Ensure-MySqlDatabase {
    param(
        [string]$PythonExe,
        [string]$DatabaseUrl
    )

    if (-not $DatabaseUrl.StartsWith("mysql://")) {
        return
    }

    $script = @"
import os
from urllib.parse import urlparse, unquote
import MySQLdb

url = urlparse(os.environ["DATABASE_URL"])
db_name = url.path.lstrip("/")
if not db_name:
    raise SystemExit("DATABASE_URL has no database name")
quote = chr(96)
escaped_db_name = db_name.replace(quote, quote + quote)
conn = MySQLdb.connect(
    host=url.hostname or "127.0.0.1",
    port=url.port or 3306,
    user=unquote(url.username or "root"),
    passwd=unquote(url.password or ""),
    connect_timeout=15,
)
cur = conn.cursor()
cur.execute("CREATE DATABASE IF NOT EXISTS {0}{1}{0} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci".format(quote, escaped_db_name))
conn.commit()
cur.close()
conn.close()
print("Database bootstrap complete: {}".format(db_name))
"@

    $tmp = [System.IO.Path]::GetTempFileName() + ".py"
    Set-Content -LiteralPath $tmp -Value $script -Encoding UTF8
    try {
        & $PythonExe $tmp
        if ($LASTEXITCODE -ne 0) {
            throw "Database bootstrap failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Write-WebConfig {
    param(
        [string]$ReleasePath,
        [string]$VenvPython,
        [string]$WFastCgi,
        [hashtable]$EnvValues
    )

    $settings = @{
        WSGI_HANDLER = "college_management_system.wsgi.application"
        PYTHONPATH = (Join-Path $DeployRoot "current")
        DJANGO_SETTINGS_MODULE = "college_management_system.settings"
        WSGI_LOG = (Join-Path $DeployRoot "logs\wfastcgi.log")
        PYTHONIOENCODING = "utf-8"
    }

    foreach ($key in $EnvValues.Keys) {
        $settings[$key] = [string]$EnvValues[$key]
    }

    $appSettings = foreach ($key in ($settings.Keys | Sort-Object)) {
        $value = [System.Security.SecurityElement]::Escape([string]$settings[$key])
        "    <add key=""$key"" value=""$value"" />"
    }

    $processor = [System.Security.SecurityElement]::Escape("$VenvPython|$WFastCgi")
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
$($appSettings -join "`r`n")
  </appSettings>
  <system.webServer>
    <handlers>
      <add name="KVTC Static Files"
           path="static/*"
           verb="GET,HEAD"
           modules="StaticFileModule"
           resourceType="File"
           requireAccess="Read" />
      <add name="KVTC Media Files"
           path="media/*"
           verb="GET,HEAD"
           modules="StaticFileModule"
           resourceType="File"
           requireAccess="Read" />
      <add name="Python FastCGI"
           path="*"
           verb="*"
           modules="FastCgiModule"
           scriptProcessor="$processor"
           resourceType="Unspecified"
           requireAccess="Script" />
    </handlers>
  </system.webServer>
</configuration>
"@

    Set-Content -LiteralPath (Join-Path $ReleasePath "web.config") -Value $xml -Encoding UTF8
}

function Write-StaticDirectoryWebConfig {
    param([string]$DirectoryPath)

    New-Item -ItemType Directory -Force -Path $DirectoryPath | Out-Null

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <clear />
      <add name="StaticFile"
           path="*"
           verb="GET,HEAD"
           modules="StaticFileModule"
           resourceType="File"
           requireAccess="Read" />
    </handlers>
  </system.webServer>
</configuration>
"@

    Set-Content -LiteralPath (Join-Path $DirectoryPath "web.config") -Value $xml -Encoding UTF8
}

function Ensure-FastCgiRegistration {
    param(
        [string]$VenvPython,
        [string]$WFastCgi
    )

    $appCmd = Join-Path $env:windir "system32\inetsrv\appcmd.exe"
    $config = (& $appCmd list config /section:system.webServer/fastCgi 2>&1) | Out-String
    if ($config -notmatch [regex]::Escape($VenvPython)) {
        $output = & $appCmd set config /section:system.webServer/fastCgi /+"[fullPath='$VenvPython',arguments='$WFastCgi']" /commit:apphost 2>&1
        if ($LASTEXITCODE -ne 0 -and (($output | Out-String) -notmatch "duplicate collection entry")) {
            $output | Write-Host
            throw "Failed to register FastCGI application."
        }
    }
}

function Ensure-IisSite {
    param([string]$PhysicalPath)

    $appCmd = Join-Path $env:windir "system32\inetsrv\appcmd.exe"

    $pool = & $appCmd list apppool /name:$AppPoolName
    if ($LASTEXITCODE -ne 0 -or -not $pool) {
        & $appCmd add apppool /name:$AppPoolName
    }

    & $appCmd set apppool $AppPoolName /managedRuntimeVersion:""

    $site = & $appCmd list site /name:$SiteName
    if ($LASTEXITCODE -ne 0 -or -not $site) {
        & $appCmd add site /name:$SiteName /bindings:"http/*:$HttpPort`:$HostHeader" /physicalPath:$PhysicalPath
    }
    else {
        & $appCmd set vdir "$SiteName/" /physicalPath:$PhysicalPath
        & $appCmd set site $SiteName /bindings:"http/*:$HttpPort`:$HostHeader"
    }

    & $appCmd set app "$SiteName/" /applicationPool:$AppPoolName
}

function Grant-AppPoolFilesystemAccess {
    param([string[]]$WritablePaths)

    $identity = "IIS AppPool\$AppPoolName"
    foreach ($path in $WritablePaths) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        & icacls $path /grant "${identity}:(OI)(CI)M" /T | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to grant $identity modify access to $path."
        }
    }
}

function Switch-CurrentRelease {
    param([string]$ReleasePath)

    $current = Join-Path $DeployRoot "current"
    $currentItem = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
    if ($currentItem) {
        if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $currentItem.PSIsContainer) {
            cmd /c rmdir "$current" | Out-Null
        }
        else {
            Remove-Item -LiteralPath $current -Force
        }

        if (Test-Path -LiteralPath $current) {
            throw "Failed to remove existing current release link: $current"
        }
    }

    cmd /c mklink /J "$current" "$ReleasePath" | Out-Null
    return $current
}

function Prune-Releases {
    $releaseRoot = Join-Path $DeployRoot "releases"
    Get-ChildItem -LiteralPath $releaseRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepReleases |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }
}

if (-not (Test-Administrator)) {
    throw "Run this script as Administrator."
}

if (-not (Test-Path $ArtifactPath)) {
    throw "Artifact not found: $ArtifactPath"
}

$DeployRoot = $DeployRoot.TrimEnd("\")
$releaseRoot = Join-Path $DeployRoot "releases"
$releasePath = Join-Path $releaseRoot $ReleaseId
$sharedMedia = Join-Path $DeployRoot "shared\media"
$logs = Join-Path $DeployRoot "logs"
$venv = Join-Path $DeployRoot ".venv"

Write-Step "Preparing folders"
New-Item -ItemType Directory -Force -Path $releaseRoot, $sharedMedia, $logs | Out-Null
if (Test-Path $releasePath) {
    Remove-Item -LiteralPath $releasePath -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $releasePath | Out-Null

Write-Step "Ensuring IIS and CGI features"
Ensure-WindowsFeature -Names @(
    "Web-Server",
    "Web-CGI",
    "Web-Static-Content",
    "Web-Default-Doc",
    "Web-Http-Errors",
    "Web-Mgmt-Console",
    "IIS-WebServerRole",
    "IIS-CGI",
    "IIS-StaticContent",
    "IIS-DefaultDocument",
    "IIS-HttpErrors",
    "IIS-ManagementConsole"
)

Write-Step "Expanding artifact"
Expand-Archive -LiteralPath $ArtifactPath -DestinationPath $releasePath -Force

if (Test-Path (Join-Path $releasePath "media")) {
    Remove-Item -LiteralPath (Join-Path $releasePath "media") -Recurse -Force
}
cmd /c mklink /J "$releasePath\media" "$sharedMedia" | Out-Null

Write-Step "Loading environment file"
$envValues = Read-EnvFile -Path $ConfigPath
Set-ProcessEnv -Values $envValues

Write-Step "Ensuring Python 3.12"
$python = Get-Python312
if (-not (Test-Path (Join-Path $venv "Scripts\python.exe"))) {
    & $python -m venv $venv
}

$venvPython = Join-Path $venv "Scripts\python.exe"
$wfastcgi = Join-Path $venv "Lib\site-packages\wfastcgi.py"

Write-Step "Installing Python dependencies"
& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r (Join-Path $releasePath "requirements.txt")

Write-Step "Ensuring database exists"
Ensure-MySqlDatabase -PythonExe $venvPython -DatabaseUrl $envValues["DATABASE_URL"]

Push-Location $releasePath
try {
    Write-Step "Running Django checks"
    & $venvPython manage.py check

    Write-Step "Running migrations"
    & $venvPython manage.py migrate --noinput

    Write-Step "Collecting static files"
    & $venvPython manage.py collectstatic --noinput --no-post-process
}
finally {
    Pop-Location
}

Write-Step "Writing static IIS web.config files"
Write-StaticDirectoryWebConfig -DirectoryPath (Join-Path $releasePath "static")
Write-StaticDirectoryWebConfig -DirectoryPath (Join-Path $releasePath "media")

Write-Step "Writing IIS web.config"
Write-WebConfig -ReleasePath $releasePath -VenvPython $venvPython -WFastCgi $wfastcgi -EnvValues $envValues

Write-Step "Registering FastCGI"
Ensure-FastCgiRegistration -VenvPython $venvPython -WFastCgi $wfastcgi

Write-Step "Stopping app pool if it exists"
$appCmd = Join-Path $env:windir "system32\inetsrv\appcmd.exe"
& $appCmd stop apppool $AppPoolName 2>$null | Out-Null

Write-Step "Switching current release"
$current = Switch-CurrentRelease -ReleasePath $releasePath

Write-Step "Configuring IIS site"
Ensure-IisSite -PhysicalPath $current

Write-Step "Granting app pool filesystem access"
Grant-AppPoolFilesystemAccess -WritablePaths @($logs, $sharedMedia)

Write-Step "Starting app pool and site"
& $appCmd start apppool $AppPoolName 2>$null | Out-Null
& $appCmd start site $SiteName 2>$null | Out-Null

Start-Sleep -Seconds 3

Write-Step "Health check"
$response = Invoke-WebRequest -Uri "http://127.0.0.1:$HttpPort/" -Headers @{ Host = $HostHeader } -UseBasicParsing -TimeoutSec 30
Write-Host "Health check status: $($response.StatusCode)"

Write-Step "Static file health check"
$staticProbe = Join-Path $current "static\css\style.css"
if (-not (Test-Path -LiteralPath $staticProbe)) {
    throw "Expected static probe file is missing: $staticProbe"
}
$staticResponse = Invoke-WebRequest -Uri "http://127.0.0.1:$HttpPort/static/css/style.css" -Headers @{ Host = $HostHeader } -UseBasicParsing -TimeoutSec 30
Write-Host "Static health check status: $($staticResponse.StatusCode)"

Write-Step "Pruning old releases"
Prune-Releases

Write-Step "Deployment complete"
Write-Host "Site: http://$HostHeader/"
Write-Host "Release: $releasePath"
