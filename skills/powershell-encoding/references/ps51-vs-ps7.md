# PowerShell 5.1 与 7 编码行为对照

本文件是 `SKILL.md` 的补充。两个版本在编码上的默认值差异很大，**跨版本协作的文件必须显式指定编码**。

## 版本识别

```powershell
$PSVersionTable.PSVersion.Major   # 5 或 7
$PSVersionTable.PSEdition         # Desktop(5.1) 或 Core(7+)
```

5.1 的可执行文件位置是 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`，
7+ 是 `pwsh.exe`。两者可以共存，**互不影响**。

## 核心差异矩阵

| 操作 | 5.1 默认 | 7+ 默认 | 风险 |
|---|---|---|---|
| `Get-Content` 读无 BOM UTF-8 | **ANSI (cp936) → 乱码** | UTF-8 → 正常 | 高。5.1 下必踩 |
| `Get-Content` 读 UTF-8 带 BOM | 正确识别 | 正确识别 | 低 |
| `Out-File` / `>` 重定向 | **UTF-16LE + BOM** | UTF-8 无 BOM | 高。跨工具读不了 |
| `Set-Content` | ANSI | UTF-8 无 BOM | 中 |
| `Set-Content -Encoding utf8` | **UTF-8 带 BOM** | UTF-8 无 BOM | 高。BOM 破坏 JSON/YAML |
| `Add-Content` | ANSI | UTF-8 无 BOM | 中 |
| `Export-Csv` | ASCII | UTF-8 无 BOM | 中 |
| `$OutputEncoding` | **us-ascii** | utf-8 | 高。管道给原生程序时中文变 `?` |
| `[Console]::OutputEncoding` | 视环境，可能 utf-8 或 ascii | utf-8 | 中。不可假设 |
| 执行 `.ps1` 脚本文件 | **需 BOM 才能正确解析中文** | 无 BOM 也可 | 高。见下节 |

## 脚本文件必须有 BOM（5.1）

**这是最容易忽略的一条。** 含中文的 `.ps1` 若以无 BOM UTF-8 保存，5.1 会按 ANSI 解析源码，
字符串字面量变成乱码，甚至因为多字节序列破坏语法而**报解析错误**（不是简单的显示乱码）。

典型报错：

```
Unexpected token '}' in expression or statement.
Missing closing '}' in statement block or type definition.
```

看起来像语法写错，实际是编码问题。识别特征：最后一行错误信息里出现乱码，
例如 `Write-Host '璇婃柇瀹屾垚'` —— 那本该是 `诊断完成`。

**修复：给脚本加 UTF-8 BOM。**

```powershell
# 给已有脚本补 BOM
$p = '.\script.ps1'
$content = [System.IO.File]::ReadAllText($p, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($p, $content, (New-Object System.Text.UTF8Encoding($true)))
```

注意：很多编辑器（含本仓库用到的写文件工具）默认写**无 BOM** UTF-8。每次编辑含中文的
`.ps1` 后都可能需要重新加 BOM。**这是本技能自身的构建约束。**

## 跨版本安全写法

以下写法在 5.1 和 7+ 行为一致，推荐作为默认。

### 读文件

```powershell
# 显式指定编码，不依赖默认值
Get-Content -Path .\f.txt -Encoding utf8
```

5.1 的 `-Encoding utf8` 读无 BOM 文件时能正确按 UTF-8 解码（虽然它写时会带 BOM）。

### 写文件（无 BOM）

```powershell
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
```

这是唯一在两个版本都稳定无 BOM 的写法。`Set-Content -Encoding utf8` 在 5.1 会带 BOM。

### 写文件（带 BOM，给 Excel 等）

```powershell
$utf8WithBom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($path, $content, $utf8WithBom)
```

### 管道传中文给原生程序

```powershell
$OutputEncoding = [System.Text.Encoding]::UTF8
'中文' | node -e "..."
```

5.1 下不设这行，中文会变成 `?`。

## 关于 BOM 的取舍

BOM 不是"好"或"坏"，取决于消费方：

| 消费方 | 需要 BOM | 原因 |
|---|---|---|
| Excel 打开 CSV | **要** | 否则按 ANSI 解释，中文乱码 |
| JSON 解析器（多数） | **不要** | BOM 会导致解析失败 |
| YAML 解析器 | **不要** | 同上 |
| Node.js 读文本 | **不要** | 一般按 UTF-8 读，BOM 会残留在首字符 |
| PowerShell 5.1 读文件 | **要**（对含中文的文件） | 无 BOM 会按 ANSI 解码 |
| Git diff / 补丁 | **不要** | BOM 会污染首行 |

**同一个文件无法同时满足所有消费方。** 按主要用途决定，并在仓库里说明。

## 一个实测基线

以下在 Windows + PowerShell 7.6.8 / 5.1.26100 上测得，可作为参考：

```
5.1:  chcp=936  Console::OutputEncoding=utf-8  $OutputEncoding=us-ascii
7.6:  chcp=936  Console::OutputEncoding=utf-8  $OutputEncoding=utf-8
```

注意 5.1 的 `Console::OutputEncoding` 在此环境是 `utf-8` 而非网上常说的 `ascii`。
**这正说明不能照抄网上的结论**，必须用 `diagnose.ps1` 实测。
