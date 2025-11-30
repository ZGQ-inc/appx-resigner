[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$CurrentDir = (Get-Location).Path
$NuGetUrl = "https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools/"
$ToolsDir = Join-Path $CurrentDir "SDKTools"
$WorkDir = Join-Path $CurrentDir "Workspace"
$FinalOutputDir = Join-Path $CurrentDir "signed"

if (-not (Test-Path $FinalOutputDir)) { New-Item -Path $FinalOutputDir -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Windows Appx Resigner"
Write-Host "==========================================" -ForegroundColor Cyan

function Get-Tools {
    $MakeAppx = Get-ChildItem -Path $ToolsDir -Filter "makeappx.exe" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like "*\x64\*" } | Select-Object -First 1
    $SignTool = Get-ChildItem -Path $ToolsDir -Filter "signtool.exe" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like "*\x64\*" } | Select-Object -First 1

    if ($MakeAppx -and $SignTool) {
        Write-Host " -> Found x64 Tools: $($MakeAppx.FullName)" -ForegroundColor DarkGray
        return @{ MakeAppx = $MakeAppx.FullName; SignTool = $SignTool.FullName }
    }

    Write-Host "Downloading SDK Tools..." -ForegroundColor Yellow
    if (Test-Path $ToolsDir) { Remove-Item $ToolsDir -Recurse -Force }
    New-Item -Path $ToolsDir -ItemType Directory -Force | Out-Null
    
    $ZipPath = Join-Path $ToolsDir "sdk_tools.zip"
    try {
        Invoke-WebRequest -Uri $NuGetUrl -OutFile $ZipPath -UseBasicParsing
    } catch {
        throw "Failed to download SDK Tools. Check internet connection."
    }

    Write-Host "Extracting tools..." -ForegroundColor DarkGray
    Expand-Archive -Path $ZipPath -DestinationPath $ToolsDir -Force
    Remove-Item $ZipPath -Force

    Write-Host "Locating x64 binaries..." -ForegroundColor Yellow
    $MakeAppx = Get-ChildItem -Path $ToolsDir -Filter "makeappx.exe" -Recurse | Where-Object { $_.FullName -like "*\x64\*" } | Select-Object -First 1
    $SignTool = Get-ChildItem -Path $ToolsDir -Filter "signtool.exe" -Recurse | Where-Object { $_.FullName -like "*\x64\*" } | Select-Object -First 1

    if (-not $MakeAppx -or -not $SignTool) { 
        throw "Failed to locate x64 tools." 
    }

    $Env:Path += ";$($MakeAppx.DirectoryName)"
    
    return @{ MakeAppx = $MakeAppx.FullName; SignTool = $SignTool.FullName }
}

function Process-Package {
    param ($SourceFile, $Tools)

    $FileName = [System.IO.Path]::GetFileName($SourceFile)
    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)
    $Extension = [System.IO.Path]::GetExtension($SourceFile)
    
    Write-Host "`n>>> Processing: $FileName" -ForegroundColor Cyan

    $RandId = Get-Random
    $UnpackDir = Join-Path $WorkDir "${BaseName}_${RandId}"
    
    if ($Extension -match "bundle") {
        Write-Host "    [Bundle] Extracting x64 component..." -ForegroundColor Yellow
        
        if (-not (Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }
        $TempZipPath = Join-Path $WorkDir "temp_${RandId}.zip"
        Copy-Item -Path $SourceFile -Destination $TempZipPath
        
        $BundleExtractDir = Join-Path $WorkDir "${BaseName}_${RandId}_Bundle"
        Expand-Archive -Path $TempZipPath -DestinationPath $BundleExtractDir -Force
        Remove-Item $TempZipPath -Force

        $InnerPackage = Get-ChildItem -Path $BundleExtractDir -Recurse | Where-Object { 
            ($_.Name -match "_x64_" -or $_.Name -match "x64") -and 
            ($_.Extension -eq ".appx" -or $_.Extension -eq ".msix") -and
            $_.Name -notmatch "Resource" 
        } | Select-Object -First 1

        if ($InnerPackage) {
            Write-Host "    [Bundle] Target found: $($InnerPackage.Name)" -ForegroundColor Green
            Process-Package -SourceFile $InnerPackage.FullName -Tools $Tools
        } else {
            Write-Warning "    [!] No x64 master package found inside bundle."
        }
        
        if (Test-Path $BundleExtractDir) { Remove-Item $BundleExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }

    $UnpackArgs = "unpack /p `"$SourceFile`" /d `"$UnpackDir`" /o"
    $p = Start-Process -FilePath $Tools.MakeAppx -ArgumentList $UnpackArgs -Wait -NoNewWindow -PassThru
    if ($p.ExitCode -ne 0) { Write-Error "    [!] Unpack failed. Code: $($p.ExitCode)"; return }

    if (-not (Test-Path "$UnpackDir\AppxManifest.xml")) { return }

    [xml]$Manifest = Get-Content "$UnpackDir\AppxManifest.xml"
    $Publisher = $Manifest.Package.Identity.Publisher
    
    $PfxPath = Join-Path $WorkDir "${BaseName}_Temp.pfx"
    $CerPath = Join-Path $FinalOutputDir "${BaseName}_SignCert.cer"

    Write-Host "    -> Generating Certificate ($Publisher)..." -ForegroundColor DarkGray
    $Cert = New-SelfSignedCertificate -Type Custom -Subject $Publisher -KeyUsage DigitalSignature -FriendlyName "Sideload-$BaseName" -CertStoreLocation "Cert:\CurrentUser\My" -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
    $Password = ConvertTo-SecureString -String "password" -Force -AsPlainText
    Export-PfxCertificate -Cert $Cert -FilePath $PfxPath -Password $Password
    Export-Certificate -Cert $Cert -FilePath $CerPath | Out-Null

    try { Import-Certificate -FilePath $CerPath -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction Stop | Out-Null } catch {}

    $TargetName = "${BaseName}_Repacked$Extension"
    $TargetPath = Join-Path $FinalOutputDir $TargetName
    $PackArgs = "pack /d `"$UnpackDir`" /p `"$TargetPath`" /o"
    Start-Process -FilePath $Tools.MakeAppx -ArgumentList $PackArgs -Wait -NoNewWindow

    Write-Host "    -> Signing..." -ForegroundColor Yellow
    $SignArgs = "sign /f `"$PfxPath`" /p password /fd SHA256 /v `"$TargetPath`""
    $s = Start-Process -FilePath $Tools.SignTool -ArgumentList $SignArgs -Wait -NoNewWindow -PassThru

    if ($s.ExitCode -eq 0) { Write-Host "    [SUCCESS] Saved to: $TargetName" -ForegroundColor Green }
    else { Write-Error "    [FAILED] Signing error code: $($s.ExitCode)" }

    if (Test-Path $UnpackDir) { Remove-Item $UnpackDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $PfxPath) { Remove-Item $PfxPath -Force -ErrorAction SilentlyContinue }
}

try {
    $Tools = Get-Tools
    
    $Files = Get-ChildItem -Path $CurrentDir -Include *.appx, *.msix, *.appxbundle, *.msixbundle -Recurse -Depth 0 | 
             Where-Object { $_.FullName -notmatch "signed" -and $_.FullName -notmatch "SDKTools" }

    if ($Files) {
        foreach ($File in $Files) { Process-Package -SourceFile $File.FullName -Tools $Tools }
    } else {
        Write-Warning "No appx/msix/bundle files found in current directory."
    }
}
catch {
    Write-Error "Critical Error: $_"
}
finally {
    if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "`nJob Finished. Check the 'signed' folder." -ForegroundColor Magenta
}