# dsh-skills

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 用的个人技能集。

技能是放在 `~/.dsh/skills/` 下的 Markdown 目录，DSH 自动发现并热加载 —— 无需重启，
无需改配置。

## 已收录

| 技能 | 用途 |
|---|---|
| [`powershell-encoding`](skills/powershell-encoding/SKILL.md) | 诊断和修复 Windows PowerShell 中文乱码 |

## 安装

### 全部安装

```powershell
git clone https://github.com/wangwei2k99/dsh-skills.git
cd dsh-skills
.\install.ps1
```

### 只装某个技能

```powershell
.\install.ps1 -Skill powershell-encoding
```

### 手动安装

把 `skills/` 下的某个目录整个复制到 `~/.dsh/skills/`：

```powershell
Copy-Item .\skills\powershell-encoding "$env:USERPROFILE\.dsh\skills\" -Recurse -Force
```

DSH 会在下一次请求前刷新技能目录，不需要重启。

## 目录结构

```
skills/
└── powershell-encoding/
    ├── SKILL.md                 # 主指令：判断流程、按症状修复、陷阱
    ├── references/
    │   ├── ps51-vs-ps7.md       # 5.1 与 7 的编码行为差异矩阵
    │   └── mojibake-table.md    # 乱码形态与成因对照、可逆性判断
    └── scripts/
        └── diagnose.ps1         # 只读诊断脚本，输出五环编码状态
```

技能采用**渐进披露**：`SKILL.md` 只放每次都要用的判断流程，细节在 `references/`
里按需加载。这是 [Agent Skills 最佳实践](https://agentskills.io/skill-creation/best-practices)
的建议，避免上下文膨胀。

## powershell-encoding 说明

### 它解决的第一个问题：别再瞎修

Windows 上的"中文乱码"不是一个问题，是**五个环节**各自可以坏：

```
文本产生 → 编码成字节 → 写入管道/文件 → 读取 → 解码显示
```

多数教程只给 `chcp 65001`，但它**只改控制台窗口显示**，对文件读写、
管道传递都不生效。技能里记录了这个区分，以及三个容易混淆的编码变量：

| 变量 | 管什么 |
|---|---|
| `chcp` | 控制台窗口如何显示 |
| `[Console]::OutputEncoding` | PowerShell 输出流用什么编码 |
| `$OutputEncoding` | 传给原生程序的字节用什么编码 |

### 一个反直觉的实测结论

**在 DeepSeek Harness 的 `pwsh` 工具里跑命令，输出中文通常不会乱码**，因为
DSH 每次调用都注入 UTF-8 前导（`pwsh -NoLogo -NoProfile -NonInteractive -Command
<encoding preamble + command>`）。

所以在 DSH 里为了"修乱码"反复设 `chcp 65001` 是无效功 —— 那不是坏的那一环。
真正还会坏的是**文件读取**：5.1 的 `Get-Content` 默认按 ANSI(cp936) 解码无 BOM
的 UTF-8 文件。

### 诊断脚本

只读，不修改任何配置 —— 诊断工具如果自己改状态，就分不清"修好了"和
"本来就是好的"。

```powershell
# 五环状态总览
pwsh -NoProfile -File scripts/diagnose.ps1

# 检查某个文件的 BOM 与可解码性
pwsh -NoProfile -File scripts/diagnose.ps1 -Path .\data.json

# 反查乱码（务必走文件，避免命令行参数自身被损坏）
pwsh -NoProfile -File scripts/diagnose.ps1 -MojibakePath .\bad.txt

# 实测 Out-File 的默认编码
pwsh -NoProfile -File scripts/diagnose.ps1 -TestFileWrite
```

同时兼容 PowerShell 5.1 和 7+，已在两者上实测通过。

## 关于乱码对照表的一个限制

`references/mojibake-table.md` 只有 18 行，不是遗漏。原本生成了 25 行，其中 7 行
的乱码形态**在写入 UTF-8 文本文件时必然损坏**，因此剔除。

原因：这些乱码里含 GBK 未定义区字符，.NET 用私用区（U+E000–U+F8FF）填充。
私用区字符不是稳定文本，经任何一次"读文本 → 写文本"都会失真。

这带来一个实用结论：**从聊天、Issue、文档里复制出来的乱码可能已与真实字节不同，
据此反查会失败。要诊断必须拿到原始文件。**

## 构建约束（给维护者）

本仓库含中文的 `.ps1` 脚本**必须带 UTF-8 BOM**。PowerShell 5.1 会用 ANSI
解析无 BOM 的脚本，导致字符串字面量变乱码，甚至因多字节序列破坏语法而报
"Unexpected token" 之类的解析错误 —— 看起来像语法写错，实际是编码问题。

很多编辑器和写文件工具默认输出**无 BOM**。每次编辑 `diagnose.ps1` 后需检查：

```powershell
$b = [System.IO.File]::ReadAllBytes('.\skills\powershell-encoding\scripts\diagnose.ps1')
# 前 3 字节必须是 239,187,191
$b[0], $b[1], $b[2]
```

`install.ps1` 会自动补 BOM。

同理，不要在 Markdown 文档里手工键入乱码示例 —— 私用区字符会丢失。本仓库的
对照表由脚本生成并逐行回环校验。

## 许可

MIT
