#Requires -Version 5.1
<#
.SYNOPSIS
    诊断 Windows PowerShell 的中文编码状态。只读，不修改任何配置。

.DESCRIPTION
    一次打印五个环节的编码状态：控制台代码页、.NET 输出流编码、
    管道输出编码、文件读写默认行为、以及可选的文件 BOM 检测。

    这个脚本刻意不设 chcp、不改 $OutputEncoding —— 诊断工具修改状态
    会让"修好了"和"本来就是好的"无法区分。

.PARAMETER Path
    要检测编码的文件路径。报告 BOM 类型、能否按 UTF-8 解码、以及
    按 GBK 解码时的样子（用于识别"UTF-8 被当 GBK"的乱码）。

.PARAMETER Mojibake
    要反查的乱码字符串。会尝试把它按 GBK 还原字节再用 UTF-8 解码。

    警告：用 `-Mojibake "涓枃"` 从命令行传参，字符可能在被脚本接收之前就已经
    被 shell 二次损坏（这正是要诊断的问题本身），导致反查结果不可信。
    优先用 -MojibakePath 从文件读取，或用 -MojibakeFromPipeline 走管道。

.PARAMETER MojibakePath
    含乱码文本的文件路径（UTF-8 保存）。比 -Mojibake 可靠，不受命令行编码影响。

.PARAMETER MojibakeFromPipeline
    从管道读取乱码文本，例如: Get-Content bad.txt | ... -MojibakeFromPipeline

.PARAMETER TestFileWrite
    额外测试 Out-File 的默认编码行为（在工作区写一个临时文件后删除）。

.EXAMPLE
    pwsh -NoProfile -File diagnose.ps1

.EXAMPLE
    pwsh -NoProfile -File diagnose.ps1 -Path .\data.json

.EXAMPLE
    # 推荐：乱码存进 UTF-8 文件后反查，避免命令行编码损耗
    pwsh -NoProfile -File diagnose.ps1 -MojibakePath .\mojibake.txt

.EXAMPLE
    # 也可走管道
    '涓枃鍐呭' | pwsh -NoProfile -File diagnose.ps1 -MojibakeFromPipeline
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$Mojibake,
    [string]$MojibakePath,
    [switch]$MojibakeFromPipeline,
    [switch]$TestFileWrite
)

$ErrorActionPreference = 'Continue'

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-Item {
    param([string]$Label, [string]$Value, [string]$Note)
    $line = "  {0,-26} {1}" -f $Label, $Value
    if ($Note) { $line += "   # $Note" }
    Write-Host $line
}

# 判断某个编码名是否等价于 UTF-8
function Test-IsUtf8 {
    param($Encoding)
    if ($null -eq $Encoding) { return $false }
    return ($Encoding.CodePage -eq 65001)
}

Write-Host 'PowerShell 编码诊断' -ForegroundColor White
Write-Host ('-' * 60)

# ── 版本 ────────────────────────────────────────────────────────────────
Write-Section '运行环境'
Write-Item 'PowerShell 版本' $PSVersionTable.PSVersion.ToString()
Write-Item 'Edition' $(if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' })
Write-Item '进程架构' $env:PROCESSOR_ARCHITECTURE
Write-Item '是否带 -NoProfile 启动' $(
    # 无法直接得知，用 profile 是否影响过变量做间接提示
    if ($PROFILE -eq $null) { 'unknown' } else { '未知（见下方 profile 检查）' }
)
$profilePath = $PROFILE.CurrentUserAllHosts
Write-Item 'CurrentUserAllHosts profile' $profilePath
Write-Item '  该 profile 是否存在' $(if (Test-Path $profilePath) { 'YES' } else { 'NO' })

# ── 五环编码 ────────────────────────────────────────────────────────────
Write-Section '① 控制台代码页（chcp）'
$codePage = $null
try {
    $codePage = [Console]::CodePage
} catch {
    $codePage = $null
}
# 输出被重定向时 [Console]::CodePage 可能返回空，回退到 chcp 命令
if (-not $codePage -or $codePage -eq 0) {
    try {
        $chcpOut = (chcp) -join ' '
        if ($chcpOut -match '(\d+)') { $codePage = [int]$Matches[1] }
    } catch {
        # chcp 不可用（非 Windows）时保持 null
    }
}
if ($codePage) {
    Write-Item 'CodePage' $codePage
} else {
    Write-Item 'CodePage' 'unavailable（输出被重定向或非 Windows）'
}
# 936 = GBK/ANSI, 65001 = UTF-8
switch ($codePage) {
    65001 { Write-Host '  → UTF-8 控制台' -ForegroundColor DarkGray }
    936   { Write-Host '  → GBK 控制台（中文 Windows 默认）；只影响窗口显示，不影响文件读写' -ForegroundColor DarkGray }
    default { Write-Host "  → 代码页 $codePage" -ForegroundColor DarkGray }
}

Write-Section '② .NET 输出流编码（Console::OutputEncoding）'
$outEnc = $null
try {
    $outEnc = [Console]::OutputEncoding
    Write-Item 'WebName' $outEnc.WebName
    Write-Item 'CodePage' $outEnc.CodePage
    if (Test-IsUtf8 $outEnc) {
        Write-Host '  → UTF-8。若 chcp 仍是 936，说明是调用方（如 DSH）注入的前导，不是系统配置' -ForegroundColor DarkGray
    } else {
        Write-Host '  → 非 UTF-8。输出中文可能乱码' -ForegroundColor Yellow
    }
} catch {
    Write-Item 'Console::OutputEncoding' "unavailable: $($_.Exception.Message)"
}

Write-Section '③ 管道输出编码（$OutputEncoding）'
# 5.1 里这个变量常是 us-ascii，导致传给原生程序的中文变问号
if ($null -ne $OutputEncoding) {
    Write-Item '$OutputEncoding' $OutputEncoding.WebName
    if ($OutputEncoding.CodePage -eq 20127) {
        Write-Host '  → us-ascii。管道传给 node/python 等原生程序时中文会变成 ? 或丢失' -ForegroundColor Yellow
        Write-Host '    修复: $OutputEncoding = [System.Text.Encoding]::UTF8' -ForegroundColor DarkGray
    } elseif (Test-IsUtf8 $OutputEncoding) {
        Write-Host '  → UTF-8，管道传递安全' -ForegroundColor DarkGray
    }
} else {
    Write-Item '$OutputEncoding' 'not set'
}

# ── 中间：当前会话能否正常输出中文 ──────────────────────────────────────
Write-Section '④ 当前会话中文输出实测'
$probe = '中文测试 ABC'
Write-Host "  输出: $probe"
$roundTrip = $probe.Length -eq 9   # 中文测试(4) + 空格(1) + ABC(3) = 8... 用长度做粗校验
$expectedLen = '中文测试 ABC'.Length
if ($probe.Length -eq $expectedLen) {
    Write-Host "  → 字符串长度 $($probe.Length)，未发生编码损坏" -ForegroundColor DarkGray
} else {
    Write-Host "  → 长度异常（$($probe.Length) / 期望 $expectedLen）" -ForegroundColor Yellow
}

# ── 文件读写 ────────────────────────────────────────────────────────────
Write-Section '⑤ 文件读写默认行为'
$is51 = $PSVersionTable.PSVersion.Major -lt 6
if ($is51) {
    Write-Host '  PowerShell 5.1:' -ForegroundColor White
    Write-Host '    Get-Content 读无 BOM UTF-8 → 按 ANSI(936) 解码，中文乱码' -ForegroundColor Yellow
    Write-Host '    Out-File / Set-Content 默认 → UTF-16LE 或 UTF-8 带 BOM' -ForegroundColor Yellow
    Write-Host '    -Encoding utf8 → 带 BOM（可能导致 JSON/YAML 解析失败）' -ForegroundColor Yellow
    Write-Host '    建议: 读取一律显式 -Encoding utf8；写入用 [System.IO.File]::WriteAllText + UTF8Encoding($false)' -ForegroundColor DarkGray
} else {
    Write-Host '  PowerShell 7+:' -ForegroundColor White
    Write-Host '    Get-Content 默认 UTF-8 → 无 BOM 文件正常' -ForegroundColor DarkGray
    Write-Host '    Out-File / Set-Content 默认 UTF-8 无 BOM' -ForegroundColor DarkGray
    Write-Host '    仍需注意: 处理 5.1 生成的文件，或需要 BOM 给 Excel 等程序' -ForegroundColor DarkGray
}

if ($TestFileWrite) {
    Write-Host ''
    Write-Host '  实测 Out-File 默认编码:' -ForegroundColor White
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("enc-probe-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        '中文' | Out-File -FilePath $tmp -Encoding utf8
        $bytes = [System.IO.File]::ReadAllBytes($tmp)
        $head = ($bytes | Select-Object -First 4) -join ','
        $bom = 'none'
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $bom = 'UTF-8 BOM (EF BB BF)' }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $bom = 'UTF-16LE BOM (FF FE)' }
        Write-Item '前 4 字节' $head
        Write-Item 'BOM' $bom
    } catch {
        Write-Item 'Out-File 测试' "failed: $($_.Exception.Message)"
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# ── 指定文件检测 ────────────────────────────────────────────────────────
if ($Path) {
    Write-Section "文件检测: $Path"
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  文件不存在" -ForegroundColor Red
    } else {
        $full = (Resolve-Path -LiteralPath $Path).Path
        $bytes = [System.IO.File]::ReadAllBytes($full)
        Write-Item '大小' "$($bytes.Length) 字节"

        # BOM 判定
        $bomKind = 'none'
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $bomKind = 'UTF-8 BOM' }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $bomKind = 'UTF-16LE BOM' }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $bomKind = 'UTF-16BE BOM' }
        Write-Item 'BOM' $bomKind

        if ($bomKind -eq 'none') {
            Write-Host '  → 无 BOM。PowerShell 5.1 的 Get-Content 会按 ANSI(936) 解码它，中文会乱码' -ForegroundColor Yellow
            Write-Host '    读取时务必 -Encoding utf8' -ForegroundColor DarkGray
        } elseif ($bomKind -eq 'UTF-8 BOM') {
            Write-Host '  → UTF-8 带 BOM。JSON/YAML/Node 等解析器可能因 BOM 报错' -ForegroundColor Yellow
        } elseif ($bomKind -like 'UTF-16*') {
            Write-Host '  → UTF-16。多数跨平台工具无法直接读取' -ForegroundColor Yellow
        }

        # 是否合法 UTF-8
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $utf8Ok = $true
        try { [void]$strictUtf8.GetString($bytes) } catch { $utf8Ok = $false }
        Write-Item '是否为合法 UTF-8' $(if ($utf8Ok) { 'YES' } else { 'NO' })

        if ($utf8Ok) {
            $asUtf8 = [System.Text.Encoding]::UTF8.GetString($bytes)
            $asGbk  = [System.Text.Encoding]::GetEncoding(936).GetString($bytes)
            $headLen = [Math]::Min(80, $asUtf8.Length)
            Write-Item '按 UTF-8 解码' ($asUtf8.Substring(0, $headLen) -replace "`r?`n", ' / ')
            if ($asGbk -ne $asUtf8) {
                Write-Item '按 GBK 解码' ($asGbk.Substring(0, [Math]::Min(80, $asGbk.Length)) -replace "`r?`n", ' / ')
                Write-Host '  → 两种解码结果不同。若你看到的是 GBK 那一行，就是 5.1 按 ANSI 读 UTF-8 导致的' -ForegroundColor DarkGray
            }
        }
    }
}

# ── 乱码反查 ────────────────────────────────────────────────────────────
# 优先从文件/管道取文本：命令行参数在到达脚本前就可能被损坏，
# 那是被诊断的问题本身，会让反查结果失去意义。
$mojiText = $null
$mojiSource = $null
if ($MojibakePath) {
    if (Test-Path -LiteralPath $MojibakePath) {
        $mojiText = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $MojibakePath).Path, [System.Text.Encoding]::UTF8)
        $mojiText = $mojiText.Trim()
        $mojiSource = "文件 $MojibakePath"
    } else {
        Write-Section '乱码反查'
        Write-Host "  文件不存在: $MojibakePath" -ForegroundColor Red
    }
} elseif ($MojibakeFromPipeline) {
    $piped = @($input)
    if ($piped.Count -gt 0) {
        $mojiText = ($piped -join "`n").Trim()
        $mojiSource = '管道'
    }
} elseif ($Mojibake) {
    $mojiText = $Mojibake
    $mojiSource = '命令行参数（可能已被 shell 损坏，结果仅供参考）'
}

if ($mojiText) {
    Write-Section "乱码反查（来源: $mojiSource）"
    Write-Host "  输入: $mojiText" -ForegroundColor DarkGray
    Write-Host '  假设: 原始 UTF-8 字节被按 GBK(936) 解码' -ForegroundColor DarkGray
    try {
        $gbk = [System.Text.Encoding]::GetEncoding(936)
        $bytes = $gbk.GetBytes($mojiText)
        $restored = [System.Text.Encoding]::UTF8.GetString($bytes)
        Write-Item '还原结果' $restored
        # 用回环校验判断是否真的恢复了：还原后能否再变回原乱码
        $reBroken = $gbk.GetString([System.Text.Encoding]::UTF8.GetBytes($restored))
        $reversible = ($reBroken -eq $mojiText)
        if ($restored -match '[\uFFFD]' -or -not $reversible) {
            Write-Host '  → 恢复不完整。原文可能经过多次不同方向的错误转换，或含 GBK 未定义区字符，不可逆' -ForegroundColor Yellow
        } else {
            Write-Host '  → 还原成功（回环校验通过）' -ForegroundColor Green
        }
    } catch {
        Write-Item '还原' "failed: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host ('-' * 60)
Write-Host '诊断完成（未修改任何配置）' -ForegroundColor Green
