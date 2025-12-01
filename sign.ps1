<#
.SYNOPSIS
    https://t.me/ZGQinc
    Windows Appx/msix/Bundle Resigner
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$CurrentDir = (Get-Location).Path
$NuGetUrl   = "https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools/"
$ToolsDir   = Join-Path $CurrentDir "SDKTools"
$WorkDir    = Join-Path $CurrentDir "Workspace"
$FinalOutputDir = Join-Path $CurrentDir "signed"

if (-not (Test-Path $FinalOutputDir)) { New-Item -Path $FinalOutputDir -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }

Write-Host "Windows Appx Resigner" -ForegroundColor Cyan

function Get-Tools {
    $SysArch = $env:PROCESSOR_ARCHITECTURE
    $TargetArch = "x64"
    if ($SysArch -match "ARM") { $TargetArch = "arm64" }
    elseif ($SysArch -eq "x86") { $TargetArch = "x86" }
    
    Write-Host "Detected System Architecture: $SysArch (Using tools for: $TargetArch)" -ForegroundColor DarkGray

    $MakeAppx = Get-ChildItem -Path $ToolsDir -Filter "makeappx.exe" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "\\$TargetArch\\" } | Select-Object -First 1
    $SignTool = Get-ChildItem -Path $ToolsDir -Filter "signtool.exe" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "\\$TargetArch\\" } | Select-Object -First 1

    if ($MakeAppx -and $SignTool) {
        return @{ MakeAppx = $MakeAppx.FullName; SignTool = $SignTool.FullName }
    }

    Write-Host "Downloading SDK Tools from NuGet..." -ForegroundColor Yellow
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

    $MakeAppx = Get-ChildItem -Path $ToolsDir -Filter "makeappx.exe" -Recurse | Where-Object { $_.FullName -match "\\$TargetArch\\" } | Select-Object -First 1
    $SignTool = Get-ChildItem -Path $ToolsDir -Filter "signtool.exe" -Recurse | Where-Object { $_.FullName -match "\\$TargetArch\\" } | Select-Object -First 1

    if (-not $MakeAppx -or -not $SignTool) { 
        throw "Failed to locate $TargetArch tools in the downloaded package." 
    }

    return @{ MakeAppx = $MakeAppx.FullName; SignTool = $SignTool.FullName }
}

function Process-Artifact {
    param (
        [string]$SourceFile,
        [hashtable]$Tools,
        [string]$ParentCertSubject = $null,
        [string]$ParentPfxPath = $null
    )

    $FileName = [System.IO.Path]::GetFileName($SourceFile)
    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)
    $Extension = [System.IO.Path]::GetExtension($SourceFile).ToLower()
    $IsBundle = ($Extension -match "bundle")

    $RandId = Get-Random
    $TaskWorkDir = Join-Path $WorkDir "${BaseName}_${RandId}"
    New-Item -Path $TaskWorkDir -ItemType Directory -Force | Out-Null

    Write-Host "`nProcessing: $FileName" -ForegroundColor Cyan

    $CertSubject = $ParentCertSubject
    $PfxPath = $ParentPfxPath
    
    if ([string]::IsNullOrEmpty($CertSubject)) {
        $PublisherName = "CN=Resigned_${BaseName}"
        $CertSubject = $PublisherName
        $PfxPath = Join-Path $FinalOutputDir "${BaseName}_SignKey.pfx"
        $CerPath = Join-Path $FinalOutputDir "${BaseName}_Root.cer"
        
        Write-Host "Generating Certificate ($PublisherName)..." -ForegroundColor DarkGray
        $Cert = New-SelfSignedCertificate -Type Custom -Subject $PublisherName -KeyUsage DigitalSignature -FriendlyName "Dev-Sideload-$BaseName" -CertStoreLocation "Cert:\CurrentUser\My" -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
        $Password = ConvertTo-SecureString -String "password" -Force -AsPlainText
        Export-PfxCertificate -Cert $Cert -FilePath $PfxPath -Password $Password
        Export-Certificate -Cert $Cert -FilePath $CerPath | Out-Null
        
        Write-Host "Certificate exported to: $CerPath" -ForegroundColor Gray
    }

    $UnpackDir = Join-Path $TaskWorkDir "Unpacked"
    if ($IsBundle) {
        Write-Host "[Bundle] Unbundling..." -ForegroundColor Yellow
        $UnpackArgs = "unbundle /p `"$SourceFile`" /d `"$UnpackDir`" /o"
        $p = Start-Process -FilePath $Tools.MakeAppx -ArgumentList $UnpackArgs -Wait -NoNewWindow -PassThru
        if ($p.ExitCode -ne 0) { Write-Error "[!] Unbundle failed. Code: $($p.ExitCode)"; return }

        $InternalPackages = Get-ChildItem -Path $UnpackDir -Include *.appx, *.msix -Recurse
        foreach ($Pkg in $InternalPackages) {
            Write-Host "[Bundle] Recursing into: $($Pkg.Name)" -ForegroundColor DarkGray
            
            $NewPkgPath = Process-Artifact -SourceFile $Pkg.FullName -Tools $Tools -ParentCertSubject $CertSubject -ParentPfxPath $PfxPath
            
            if ($NewPkgPath -and (Test-Path $NewPkgPath)) {
                Copy-Item -Path $NewPkgPath -Destination $Pkg.FullName -Force
            } else {
                Write-Error "[!] Failed to process internal package: $($Pkg.Name)"
                return
            }
        }
    } else {
        Write-Host "[Package] Unpacking..." -ForegroundColor Yellow
        $UnpackArgs = "unpack /p `"$SourceFile`" /d `"$UnpackDir`" /o"
        $p = Start-Process -FilePath $Tools.MakeAppx -ArgumentList $UnpackArgs -Wait -NoNewWindow -PassThru
        if ($p.ExitCode -ne 0) { Write-Error "[!] Unpack failed. Code: $($p.ExitCode)"; return }

        $ManifestPath = Join-Path $UnpackDir "AppxManifest.xml"
        if (Test-Path $ManifestPath) {
            Write-Host "Updating Manifest Publisher..." -ForegroundColor DarkGray
            [xml]$Xml = Get-Content $ManifestPath
            $Xml.Package.Identity.Publisher = $CertSubject
            $Xml.Save($ManifestPath)
        }
    }

    if ($ParentCertSubject) {
        $OutputName = $FileName
        $OutputDir = Join-Path $FinalOutputDir "Temp_Internal"
        if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory | Out-Null }
    } else {
        $OutputName = "${BaseName}_Repacked$Extension"
        $OutputDir = $FinalOutputDir
    }

    $TargetPackPath = Join-Path $OutputDir $OutputName
    
    if ($IsBundle) {
        Write-Host "[Bundle] Rebuilding Bundle..." -ForegroundColor Yellow
        $PackArgs = "bundle /d `"$UnpackDir`" /p `"$TargetPackPath`" /o"
    } else {
        Write-Host "[Package] Repacking..." -ForegroundColor Yellow
        $PackArgs = "pack /d `"$UnpackDir`" /p `"$TargetPackPath`" /o"
    }

    $p = Start-Process -FilePath $Tools.MakeAppx -ArgumentList $PackArgs -Wait -NoNewWindow -PassThru
    if ($p.ExitCode -ne 0) { Write-Error "[!] Repack failed. Code: $($p.ExitCode)"; return $null }

    Write-Host "Signing ($OutputName)..." -ForegroundColor Yellow
    $SignArgs = "sign /f `"$PfxPath`" /p password /fd SHA256 /v `"$TargetPackPath`""
    $s = Start-Process -FilePath $Tools.SignTool -ArgumentList $SignArgs -Wait -NoNewWindow -PassThru

    if ($s.ExitCode -eq 0) { 
        if (-not $ParentCertSubject) { Write-Host "[SUCCESS] Finished: $TargetPackPath" -ForegroundColor Green }
    } else { 
        Write-Error "[FAILED] Signing error code: $($s.ExitCode)" 
        return $null
    }

    if (Test-Path $TaskWorkDir) { Remove-Item $TaskWorkDir -Recurse -Force -ErrorAction SilentlyContinue }

    return $TargetPackPath
}

try {
    $Tools = Get-Tools
    
    $Files = Get-ChildItem -Path $CurrentDir -Include *.appx, *.msix, *.appxbundle, *.msixbundle -Recurse -Depth 0 | 
             Where-Object { $_.FullName -notmatch "signed" -and $_.FullName -notmatch "SDKTools" -and $_.FullName -notmatch "Workspace" }

    if ($Files) {
        foreach ($File in $Files) { 
            Process-Artifact -SourceFile $File.FullName -Tools $Tools 
        }
    } else {
        Write-Warning "No appx/msix/bundle files found in current directory."
    }
}
catch {
    Write-Error "Critical Error: $_"
}
finally {
    if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path (Join-Path $FinalOutputDir "Temp_Internal")) { Remove-Item (Join-Path $FinalOutputDir "Temp_Internal") -Recurse -Force -ErrorAction SilentlyContinue }
    
    Write-Host "`nJob Finished." -ForegroundColor Magenta
}
