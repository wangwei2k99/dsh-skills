---
name: powershell-encoding
description: "诊断和修复 Windows PowerShell 中文乱码：输出中文显示为怪字或问号方块、脚本与数据文件读取中文异常、Out-File 写出的文件其他程序读不了、原生程序管道传中文损坏、PowerShell 5.1 与 7 行为不一致、BOM 缺失与多余。当任务涉及 Windows 上中文文本的显示、读写或跨程序传递时使用。"
---

# PowerShell 中文乱码

## 先判断：乱码在哪一环

Windows 上的"中文乱码"不是一个问题，是**五个不同环节**各自可以坏。动手前先定位，否则会在错误的层反复试。

```
文本产生 → 编码成字节 → 写入管道/文件 → 读取 → 解码显示
   ↑           ↑              ↑            ↑        ↑
  ①源        ②输出编码      ③存储格式    ④读取    ⑤控制台
```

**默认先跑诊断脚本**，它会一次打印全部五环的状态：

```powershell
pwsh -NoProfile -File scripts/diagnose.ps1
```

需要针对具体文件或已损坏文本时：

```powershell
# 检测文件编码/BOM
pwsh -NoProfile -File scripts/diagnose.ps1 -Path .\data.json

# 反查乱码：务必从文件读，不要用 -Mojibake 传参（见下）
pwsh -NoProfile -File scripts/diagnose.ps1 -MojibakePath .\bad.txt
```

**为什么乱码反查要走文件而不是命令行参数**：`-Mojibake "..."` 的字符串在到达脚本前
可能已被 shell 按错误编码转换，等于用坏掉的输入做诊断。实测同样的内容，走命令行
得到错误结果，走文件读取才正确。若必须用管道，用 `-MojibakeFromPipeline`。

## 最重要的反直觉事实

**在 DeepSeek Harness 的 `pwsh` 工具里跑命令，输出中文通常不会乱码，因为它每次都注入 UTF-8 前导。**

所以在 DSH 里看到中文正常，**不代表系统已经配好**——换到终端、其他程序、或读文件时照样会坏。反之，在 DSH 里为了"修乱码"而反复设 `chcp 65001` 通常是无效功，因为那不是坏的那一环。

判断方法：看 `[Console]::OutputEncoding`。若是 `utf-8` 而 `chcp` 仍是 `936`，说明是 DSH 注入的，不是系统配置。

## 三个编码变量，含义完全不同

这是最容易误诊的地方。网上教程大多只说 `chcp`，那只是三分之一。

| 变量 | 层 | 管什么 | 典型陷阱 |
|---|---|---|---|
| `chcp` / `[Console]::CodePage` | Win32 控制台 | 控制台**窗口**如何显示字节 | 改成 65001 只影响当前窗口，不改文件读写 |
| `[Console]::OutputEncoding` | .NET 流 | PowerShell **输出流**用什么编码 | 5.1 默认可能是 utf-8 或 ascii，取决于环境，**不可假设** |
| `$OutputEncoding` | 管道 | 传给**原生程序**的字节用什么编码 | 5.1 默认常是 `us-ascii`，中文会变 `?` |

**只改 `chcp` 无法修复文件读取问题。** 文件解码由各 cmdlet 自己的默认参数决定。

## PowerShell 5.1 vs 7 的核心差异

| 行为 | 5.1 | 7+ |
|---|---|---|
| `Get-Content` 读无 BOM UTF-8 | **按 ANSI(cp936) 解码 → 乱码** | 默认 UTF-8 → 正常 |
| `Out-File` 默认编码 | **UTF-16LE（有 BOM）** | UTF-8 无 BOM |
| `Set-Content -Encoding UTF8` | UTF-8 **带 BOM** | UTF-8 无 BOM |
| `$OutputEncoding` | 常为 `us-ascii` | `utf-8` |
| 默认参数差异 | 必须显式指定 | 多数场景可用默认 |

**结论：跨版本协作的文件必须显式指定编码，不能依赖默认值。**

详见 `references/ps51-vs-ps7.md`。

## 按症状修复

### 症状：`Get-Content` 读出的中文是 `娴嬭瘯` 这类"看起来像乱码的中文"

原因：UTF-8 字节被按 GBK 解码（5.1 的默认行为）。

```powershell
# 5.1 和 7 都通用的写法
Get-Content -Path .\file.txt -Encoding utf8
```

不要用 `chcp 65001` 解决——它不改 `Get-Content` 的解码方式。

### 症状：`Out-File` 写出的文件在别的程序里乱码

原因：5.1 默认写 UTF-16LE，很多程序（尤其 Node、Python、Git）按 UTF-8 读。

```powershell
# 明确要 UTF-8 且不要 BOM（跨工具最安全）
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $content, $utf8NoBom)

# 或者用 cmdlet，7 里 -Encoding utf8 就是无 BOM
$content | Set-Content -Path $path -Encoding utf8
```

**5.1 的 `-Encoding utf8` 会带 BOM**，某些解析器（JSON、YAML、shell 脚本首行）会因为 BOM 报错。要无 BOM 必须走 .NET API。

### 症状：管道传给 node/python 等原生程序，中文变成 `?` 或截断

原因：`$OutputEncoding` 在 5.1 里常是 `us-ascii`。

```powershell
$OutputEncoding = [System.Text.Encoding]::UTF8
'中文内容' | node -e "process.stdin.on('data',d=>console.log(d.toString()))"
```

### 症状：需要 BOM 才能让某程序识别（少数情况）

```powershell
$utf8WithBom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($path, $content, $utf8WithBom)
```

Excel 打开 CSV 需要 BOM，否则中文乱码。Git、Node、JSON 解析通常**不要** BOM。这个冲突无法同时满足，只能按消费方决定。

### 症状：已损坏的文本要反查原文

拿到 `娴嬭瘯` 这类字符串，说明它原本是 UTF-8 字节被按 GBK 解过。反向恢复：

```powershell
# 把乱码按 GBK 还原成字节，再按 UTF-8 解码
$bytes = [System.Text.Encoding]::GetEncoding(936).GetBytes($mojibake)
[System.Text.Encoding]::UTF8.GetString($bytes)
```

常见对照见 `references/mojibake-table.md`。**注意：这种恢复只在"UTF-8 被当 GBK"时成立**，其他方向的损坏（如 `锟斤拷` 是多次错误替换）不可逆。

## 陷阱

- **`chcp 65001` 不是万能药。** 它只改控制台窗口的显示，对 `Get-Content`、`Out-File`、`$OutputEncoding` 都不生效。很多教程只给这一条，会让人误以为修好了。
- **`chcp` 只影响当前进程/窗口。** 改完开新窗口就回去了，不是持久配置。
- **不要把 `chcp 65001` 写进 `$PROFILE` 当作根治。** DSH 的 pwsh 工具用 `-NoProfile` 启动，profile 根本不会加载；而且它已经自己注入了编码前导。
- **`[Console]::OutputEncoding = utf8` 在 5.1 里可能抛异常**，当输出被重定向到非控制台时无法设置。用 `$OutputEncoding` 配合显式编码参数更稳。
- **BOM 是有害还是必需取决于消费方。** 不要全局加或全局去，按目标程序决定。
- **`-Encoding utf8` 在 5.1 和 7 语义不同**（前者带 BOM），这是最常见的跨版本 bug 来源。
- **中文的 token/字符计数不是 1:1。** 一个汉字在 UTF-8 里是 3 字节，在某些 token 估算里会被低估，不要用字节数推断字符数。

## 环境事实（本机实测）

以下是在实际 Windows 环境上测得，可作为判断基线，但不同机器可能不同，**以 `diagnose.ps1` 的输出为准**：

- Windows PowerShell 5.1 的 `[Console]::OutputEncoding` 实测为 `utf-8`，`chcp` 为 `936`，`$OutputEncoding` 为 `us-ascii`
- PowerShell 7.6.8 的 `$OutputEncoding` 为 `utf-8`
- 5.1 读无 BOM UTF-8 文件时，中文会被按 GBK 解码成一串怪字（`娴嬭瘯鏂囦欢` 这类形态），实测确认可复现
- DSH 的 `pwsh` 工具输出的中文正常（内置编码前导）

## 进一步

- `references/ps51-vs-ps7.md` — 两个版本的完整行为差异矩阵
- `references/mojibake-table.md` — 乱码形态与成因对照
