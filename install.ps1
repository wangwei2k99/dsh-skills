#Requires -Version 5.1
<#
.SYNOPSIS
    把本仓库的 DSH 技能安装到 ~/.dsh/skills。

.DESCRIPTION
    复制 skills/ 下的技能目录到 DSH 的技能根目录，并确保 .ps1 脚本带 UTF-8 BOM
    （PowerShell 5.1 解析无 BOM 的中文脚本会失败）。

    DSH 会自动发现新技能并热加载，安装后无需重启。

.PARAMETER Skill
    只安装指定的技能名（对应 skills/ 下的目录名）。省略则安装全部。

.PARAMETER Force
    覆盖已存在的同名技能。

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Skill powershell-encoding -Force
#>
[CmdletBinding()]
param(
    [string]$Skill,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Join-Path $repoRoot 'skills'
$destRoot = Join-Path (Join-Path $HOME '.dsh') 'skills'

if (-not (Test-Path $sourceRoot)) {
    throw "找不到技能源目录: $sourceRoot"
}

# 确定要安装的技能目录
if ($Skill) {
    $targets = @(Join-Path $sourceRoot $Skill)
    if (-not (Test-Path $targets[0])) {
        $available = (Get-ChildItem $sourceRoot -Directory | Select-Object -ExpandProperty Name) -join ', '
        throw "技能不存在: $Skill。可用: $available"
    }
} else {
    $targets = @(Get-ChildItem $sourceRoot -Directory | Select-Object -ExpandProperty FullName)
}

if ($targets.Count -eq 0) {
    throw "skills/ 下没有技能目录"
}

Write-Host "安装到: $destRoot" -ForegroundColor Cyan
if (-not (Test-Path $destRoot)) {
    New-Item -ItemType Directory -Force -Path $destRoot | Out-Null
    Write-Host '  (已创建技能目录)' -ForegroundColor DarkGray
}

$installed = 0

foreach ($src in $targets) {
    $name = Split-Path -Leaf $src
    $dst = Join-Path $destRoot $name

    if ((Test-Path $dst) -and -not $Force) {
        Write-Host "  跳过 $name（已存在，用 -Force 覆盖）" -ForegroundColor Yellow
        continue
    }

    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    Copy-Item $src $dst -Recurse -Force

    # 确保所有 .ps1 带 UTF-8 BOM，否则 5.1 无法正确解析中文
    $psFiles = @(Get-ChildItem $dst -Recurse -File -Filter '*.ps1')
    foreach ($ps in $psFiles) {
        $bytes = [System.IO.File]::ReadAllBytes($ps.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $hasBom) {
            $text = [System.IO.File]::ReadAllText($ps.FullName, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText($ps.FullName, $text, (New-Object System.Text.UTF8Encoding($true)))
            Write-Host "    补 BOM: $($ps.Name)" -ForegroundColor DarkGray
        }
    }

    Write-Host "  已安装 $name" -ForegroundColor Green
    $installed++
}

Write-Host ''
Write-Host "完成：$installed 个技能已安装。" -ForegroundColor Green
Write-Host 'DSH 会自动发现并热加载，无需重启。' -ForegroundColor DarkGray
Write-Host ''
Write-Host '验证：在 DSH 里让模型调用 skill 工具，或查看技能目录是否包含新技能。' -ForegroundColor DarkGray
