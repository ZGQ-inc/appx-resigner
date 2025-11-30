[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# 配置
$CurrentDir = (Get-Location).Path
$NuGetUrl = "https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools/"
$ToolsDir = Join-Path $CurrentDir "SDKTools_Temp"
$WorkDir = Join-Path $CurrentDir "Workspace_Temp"
$FinalOutputDir = Join-Path $CurrentDir "signed"

if (-not (Test-Path $FinalOutputDir)) { New-Item -Path $FinalOutputDir -ItemType Directory | Out-Null }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Windows 应用包重签" -ForegroundColor Cyan
Write-Host "   工作目录: $CurrentDir" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan

function Setup-Environment {
    Write-Host "[*] 正在检查 SDK 工具环境..." -ForegroundColor Cyan
    
    $MakeAppx = Get-ChildItem -Path $ToolsDir -Filter "makeappx.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $SignTool = Get-ChildItem -Path $ToolsDir -Filter "signtool.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($MakeAppx -and $SignTool) {
        return @{ MakeAppx = $MakeAppx.FullName; SignTool = $SignTool.FullName }
    }

    Write-Host "    -> 正在拉取微软官方 SDK 工具 (NuGet)..." -ForegroundColor Yellow
    if (-not (Test-Path $ToolsDir)) { New-Item -Path $ToolsDir -ItemType Directory | Out-Null }
    $ZipPath = Join-Path $ToolsDir "sdk_tools.zip"
    
    try {
        Invoke-WebRequest -Uri $NuGetUrl -OutFile $ZipPath -UseBasicParsing
    } catch {
        Write-Error "SDK 下载失败，请检查网络连接。"
        throw $_
    }

    Write-Host "    -> 解压工具中..." -ForegroundColor DarkGray
    Expand-Archive -Path $ZipPath -DestinationPath $ToolsDir -Force
    Remove-Item $ZipPath -Force

    $MakeAppx = Get-ChildItem -Path $ToolsDir -Filter "makeappx.exe" -Recurse | Where-Object { $_.DirectoryName -like "*x64*" } | Select-Object -First 1
    $SignTool = Get-ChildItem -Path $ToolsDir -Filter "signtool.exe" -Recurse | Where-Object { $_.DirectoryName -like "*x64*" } | Select-Object -First 1

    if (-not $MakeAppx -or -not $SignTool) {
        Write-Error "工具提取失败。"
        throw "Missing Tools"
    }

    $Env:Path += ";$($MakeAppx.DirectoryName)"
    
    return @{ MakeAppx = $MakeAppx.FullName; SignTool = $SignTool.FullName }
}

function Process-SinglePackage {
    param ($SourceFile, $Tools)

    $FileName = [System.IO.Path]::GetFileName($SourceFile)
    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)
    $Extension = [System.IO.Path]::GetExtension($SourceFile)
    
    Write-Host "`n>>> 处理: $FileName" -ForegroundColor Cyan

    $RandId = Get-Random
    $UnpackDir = Join-Path $WorkDir "${BaseName}_${RandId}"
    
    if ($Extension -match "bundle") {
        Write-Host "    [Bundle] 解包提取 x64 组件..." -ForegroundColor Yellow
        $BundleExtractDir = Join-Path $WorkDir "${BaseName}_${RandId}_Bundle"
        Expand-Archive -Path $SourceFile -DestinationPath $BundleExtractDir -Force

        $InnerPackage = Get-ChildItem -Path $BundleExtractDir -Recurse | Where-Object { 
            ($_.Name -match "_x64_" -or $_.Name -match "x64") -and 
            ($_.Extension -eq ".appx" -or $_.Extension -eq ".msix") -and
            $_.Name -notmatch "Resource" 
        } | Select-Object -First 1

        if ($InnerPackage) {
            Write-Host "    [Bundle] 锁定目标: $($InnerPackage.Name)" -ForegroundColor Green
            Process-SinglePackage -SourceFile $InnerPackage.FullName -Tools $Tools
        } else {
            Write-Warning "    [!] Bundle 中未找到 x64 主程序。"
        }
        return
    }

    $UnpackArgs = "unpack /p `"$SourceFile`" /d `"$UnpackDir`" /o"
    $p = Start-Process -FilePath $Tools.MakeAppx -ArgumentList $UnpackArgs -Wait -NoNewWindow -PassThru
    if ($p.ExitCode -ne 0) { Write-Error "    [!] 解包失败"; return }

    if (-not (Test-Path "$UnpackDir\AppxManifest.xml")) { return }

    [xml]$Manifest = Get-Content "$UnpackDir\AppxManifest.xml"
    $Publisher = $Manifest.Package.Identity.Publisher
    
    $PfxPath = Join-Path $WorkDir "${BaseName}_Temp.pfx"
    $CerPath = Join-Path $FinalOutputDir "${BaseName}_SignCert.cer"

    Write-Host "    -> 生成证书 ($Publisher)..." -ForegroundColor DarkGray
    $Cert = New-SelfSignedCertificate -Type Custom -Subject $Publisher -KeyUsage DigitalSignature -FriendlyName "Sideload-$BaseName" -CertStoreLocation "Cert:\CurrentUser\My" -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
    $Password = ConvertTo-SecureString -String "password" -Force -AsPlainText
    Export-PfxCertificate -Cert $Cert -FilePath $PfxPath -Password $Password
    Export-Certificate -Cert $Cert -FilePath $CerPath | Out-Null

    try { Import-Certificate -FilePath $CerPath -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction Stop | Out-Null } catch {}

    $TargetName = "${BaseName}_Repacked$Extension"
    $TargetPath = Join-Path $FinalOutputDir $TargetName
    $PackArgs = "pack /d `"$UnpackDir`" /p `"$TargetPath`" /o"
    Start-Process -FilePath $Tools.MakeAppx -ArgumentList $PackArgs -Wait -NoNewWindow

    Write-Host "    -> 签名..." -ForegroundColor Yellow
    $SignArgs = "sign /f `"$PfxPath`" /p password /fd SHA256 /v `"$TargetPath`""
    $s = Start-Process -FilePath $Tools.SignTool -ArgumentList $SignArgs -Wait -NoNewWindow -PassThru

    if ($s.ExitCode -eq 0) { Write-Host "    [√] 成功: $TargetName" -ForegroundColor Green }
    else { Write-Error "    [X] 签名失败" }
}

try {
    $Tools = Setup-Environment

    $Files = Get-ChildItem -Path $CurrentDir -Include *.appx, *.msix, *.appxbundle, *.msixbundle -Recurse -Depth 0 | 
             Where-Object { $_.FullName -notmatch "signed" -and $_.FullName -notmatch "SDKTools" }

    if ($Files) {
        foreach ($File in $Files) { Process-SinglePackage -SourceFile $File.FullName -Tools $Tools }
    } else {
        Write-Warning "当前目录下没有找到安装包。"
    }
}
catch {
    Write-Error "发生错误: $_"
}
finally {
    # if (Test-Path $ToolsDir) { Remove-Item $ToolsDir -Recurse -Force }
    if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "`n处理结束。" -ForegroundColor Magenta
}