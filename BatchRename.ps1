# ============================================================
#  批量重命名工具 - PowerShell + WinForms GUI
#  无需安装依赖，Windows 自带 PowerShell + .NET 即可运行
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 脚本目录与日志目录
if ($PSScriptRoot) {
    $script:ScriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $script:ScriptDir = (Get-Location).Path
}
$script:LogDir = Join-Path $script:ScriptDir 'logs'
if (-not (Test-Path $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

# 预览缓存：每项 = @{FullName; OldName; NewName; IsFolder; Status}
$script:PreviewItems = New-Object System.Collections.ArrayList

# ------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------

function Convert-WildcardToRegex {
    param([string]$Wildcard)
    if ([string]::IsNullOrEmpty($Wildcard)) { return '' }
    $escaped = [regex]::Escape($Wildcard)
    $escaped = $escaped -replace '\\\*', '.*'
    $escaped = $escaped -replace '\\\?', '.'
    return $escaped
}

function Get-NewName {
    param(
        [string]$Name,
        [bool]$IsFolder,
        [string]$Mode,      # keyword / position / pattern
        [string]$Action,    # replace / delete / insert
        [hashtable]$P
    )

    # 文件夹不分扩展名；文件根据 IncludeExt 决定
    if ($IsFolder -or $P.IncludeExt) {
        $base = $Name
        $ext  = ''
    } else {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
        $ext  = [System.IO.Path]::GetExtension($Name)
    }
    $t = $base

    try {
        switch ($Mode) {
            'keyword' {
                switch ($Action) {
                    'replace' {
                        if ([string]::IsNullOrEmpty($P.Find)) { return $Name }
                        $t = $t.Replace($P.Find, [string]$P.Replace)
                    }
                    'delete' {
                        if ([string]::IsNullOrEmpty($P.Find)) { return $Name }
                        $t = $t.Replace($P.Find, '')
                    }
                    'insert' {
                        $idx = if ($P.FromEnd) {
                            [Math]::Max(0, $t.Length - [int]$P.Position)
                        } else {
                            [Math]::Min($t.Length, [int]$P.Position)
                        }
                        $t = $t.Insert($idx, [string]$P.Replace)
                    }
                }
            }
            'position' {
                $pos = [int]$P.Position
                $len = [int]$P.Length
                if ($P.FromEnd) {
                    $start = $t.Length - $pos - $len
                } else {
                    $start = $pos
                }
                if ($start -lt 0) { $start = 0 }
                if ($start -gt $t.Length) { $start = $t.Length }
                $end = $start + $len
                if ($end -gt $t.Length) { $end = $t.Length }
                $actLen = $end - $start
                switch ($Action) {
                    'replace' {
                        if ($actLen -gt 0) { $t = $t.Remove($start, $actLen) }
                        $t = $t.Insert($start, [string]$P.Replace)
                    }
                    'delete' {
                        if ($actLen -gt 0) { $t = $t.Remove($start, $actLen) }
                    }
                    'insert' {
                        $insIdx = if ($P.FromEnd) {
                            [Math]::Max(0, $t.Length - $pos)
                        } else {
                            [Math]::Min($t.Length, $pos)
                        }
                        $t = $t.Insert($insIdx, [string]$P.Replace)
                    }
                }
            }
            'pattern' {
                $regex = Convert-WildcardToRegex $P.Find
                if ([string]::IsNullOrEmpty($P.Find) -and $Action -ne 'insert') {
                    return $Name
                }
                switch ($Action) {
                    'replace' { if ($regex) { $t = [regex]::Replace($t, $regex, [string]$P.Replace) } }
                    'delete'  { if ($regex) { $t = [regex]::Replace($t, $regex, '') } }
                    'insert'  {
                        $idx = if ($P.FromEnd) {
                            [Math]::Max(0, $t.Length - [int]$P.Position)
                        } else {
                            [Math]::Min($t.Length, [int]$P.Position)
                        }
                        $t = $t.Insert($idx, [string]$P.Replace)
                    }
                }
            }
        }
    } catch {
        return $Name
    }

    return $t + $ext
}

function Get-TargetItems {
    param(
        [string]$Folder,
        [bool]$Recursive,
        [int]$Depth,            # 0 = 无限
        [string]$ItemType       # file / folder / both
    )
    $results = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Folder)) { return $results }

    $rootFull = (Get-Item -LiteralPath $Folder).FullName.TrimEnd('\')

    if ($Recursive) {
        $all = Get-ChildItem -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        $all = Get-ChildItem -LiteralPath $Folder -Force -ErrorAction SilentlyContinue
    }

    foreach ($it in $all) {
        if ($Recursive -and $Depth -gt 0) {
            $itemFull = $it.FullName.TrimEnd('\')
            if ($itemFull.Length -le $rootFull.Length) { continue }
            $rel = $itemFull.Substring($rootFull.Length).TrimStart('\')
            if ([string]::IsNullOrEmpty($rel)) { continue }
            $segs = $rel.Split([char[]]@('\','/'), [StringSplitOptions]::RemoveEmptyEntries)
            # 深度语义：向下进入几层子文件夹
            #  - 文件项的实际深度 = 其父目录距根的层数 = segs.Count - 1
            #  - 文件夹项的实际深度 = 其自身距根的层数 = segs.Count
            $effDepth = if ($it.PSIsContainer) { $segs.Count } else { $segs.Count - 1 }
            if ($effDepth -gt $Depth) { continue }
        }
        $isDir = $it.PSIsContainer
        switch ($ItemType) {
            'file'   { if (-not $isDir) { [void]$results.Add($it) } }
            'folder' { if ($isDir)      { [void]$results.Add($it) } }
            default  { [void]$results.Add($it) }
        }
    }

    # 重命名时为避免父目录改名导致子项路径失效，按路径深度倒序
    $sorted = $results | Sort-Object -Property @{
        Expression = { $_.FullName.Length }
        Descending = $true
    }
    return ,@($sorted)
}

# ------------------------------------------------------------
# GUI 构建
# ------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = '批量重命名工具'
$form.Size = New-Object System.Drawing.Size(960, 720)
$form.MinimumSize = New-Object System.Drawing.Size(880, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

# ----- 顶部：文件夹选择 -----
$grpTop = New-Object System.Windows.Forms.GroupBox
$grpTop.Text = '1. 选择目标文件夹与范围'
$grpTop.Location = New-Object System.Drawing.Point(10, 8)
$grpTop.Size = New-Object System.Drawing.Size(925, 110)
$grpTop.Anchor = 'Top, Left, Right'
$form.Controls.Add($grpTop)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text = '目标文件夹:'
$lblFolder.Location = New-Object System.Drawing.Point(12, 28)
$lblFolder.Size = New-Object System.Drawing.Size(80, 20)
$grpTop.Controls.Add($lblFolder)

$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(95, 25)
$txtFolder.Size = New-Object System.Drawing.Size(700, 24)
$txtFolder.Anchor = 'Top, Left, Right'
$grpTop.Controls.Add($txtFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '浏览...'
$btnBrowse.Location = New-Object System.Drawing.Point(805, 24)
$btnBrowse.Size = New-Object System.Drawing.Size(100, 26)
$btnBrowse.Anchor = 'Top, Right'
$grpTop.Controls.Add($btnBrowse)

$chkRecursive = New-Object System.Windows.Forms.CheckBox
$chkRecursive.Text = '包含子文件夹'
$chkRecursive.Location = New-Object System.Drawing.Point(12, 65)
$chkRecursive.Size = New-Object System.Drawing.Size(110, 24)
$grpTop.Controls.Add($chkRecursive)

$lblDepth = New-Object System.Windows.Forms.Label
$lblDepth.Text = '深度(0=无限):'
$lblDepth.Location = New-Object System.Drawing.Point(130, 68)
$lblDepth.Size = New-Object System.Drawing.Size(85, 20)
$grpTop.Controls.Add($lblDepth)

$numDepth = New-Object System.Windows.Forms.NumericUpDown
$numDepth.Location = New-Object System.Drawing.Point(220, 65)
$numDepth.Size = New-Object System.Drawing.Size(60, 24)
$numDepth.Minimum = 0
$numDepth.Maximum = 99
$numDepth.Value = 0
$numDepth.Enabled = $false
$grpTop.Controls.Add($numDepth)

$lblScope = New-Object System.Windows.Forms.Label
$lblScope.Text = '处理对象:'
$lblScope.Location = New-Object System.Drawing.Point(310, 68)
$lblScope.Size = New-Object System.Drawing.Size(70, 20)
$grpTop.Controls.Add($lblScope)

$rbFile = New-Object System.Windows.Forms.RadioButton
$rbFile.Text = '仅文件'
$rbFile.Location = New-Object System.Drawing.Point(380, 65)
$rbFile.Size = New-Object System.Drawing.Size(70, 24)
$rbFile.Checked = $true
$grpTop.Controls.Add($rbFile)

$rbFolder = New-Object System.Windows.Forms.RadioButton
$rbFolder.Text = '仅文件夹'
$rbFolder.Location = New-Object System.Drawing.Point(455, 65)
$rbFolder.Size = New-Object System.Drawing.Size(80, 24)
$grpTop.Controls.Add($rbFolder)

$rbBoth = New-Object System.Windows.Forms.RadioButton
$rbBoth.Text = '文件和文件夹'
$rbBoth.Location = New-Object System.Drawing.Point(540, 65)
$rbBoth.Size = New-Object System.Drawing.Size(110, 24)
$grpTop.Controls.Add($rbBoth)

$chkIncludeExt = New-Object System.Windows.Forms.CheckBox
$chkIncludeExt.Text = '处理时包含扩展名'
$chkIncludeExt.Location = New-Object System.Drawing.Point(660, 65)
$chkIncludeExt.Size = New-Object System.Drawing.Size(150, 24)
$chkIncludeExt.Checked = $false
$grpTop.Controls.Add($chkIncludeExt)

# ----- 中部：重命名模式 TabControl -----
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = '2. 选择重命名模式'
$grpMode.Location = New-Object System.Drawing.Point(10, 125)
$grpMode.Size = New-Object System.Drawing.Size(925, 200)
$grpMode.Anchor = 'Top, Left, Right'
$form.Controls.Add($grpMode)

$tabMode = New-Object System.Windows.Forms.TabControl
$tabMode.Location = New-Object System.Drawing.Point(10, 22)
$tabMode.Size = New-Object System.Drawing.Size(905, 170)
$tabMode.Anchor = 'Top, Left, Right'
$grpMode.Controls.Add($tabMode)

# === Tab 1: 关键字 ===
$tabKey = New-Object System.Windows.Forms.TabPage
$tabKey.Text = '关键字'
$tabMode.TabPages.Add($tabKey)

$lblKAct = New-Object System.Windows.Forms.Label
$lblKAct.Text = '操作:'
$lblKAct.Location = New-Object System.Drawing.Point(12, 18)
$lblKAct.Size = New-Object System.Drawing.Size(40, 20)
$tabKey.Controls.Add($lblKAct)

$rbKReplace = New-Object System.Windows.Forms.RadioButton
$rbKReplace.Text = '替换'
$rbKReplace.Location = New-Object System.Drawing.Point(55, 15)
$rbKReplace.Size = New-Object System.Drawing.Size(60, 24)
$rbKReplace.Checked = $true
$tabKey.Controls.Add($rbKReplace)

$rbKDelete = New-Object System.Windows.Forms.RadioButton
$rbKDelete.Text = '删除'
$rbKDelete.Location = New-Object System.Drawing.Point(120, 15)
$rbKDelete.Size = New-Object System.Drawing.Size(60, 24)
$tabKey.Controls.Add($rbKDelete)

$rbKInsert = New-Object System.Windows.Forms.RadioButton
$rbKInsert.Text = '增加'
$rbKInsert.Location = New-Object System.Drawing.Point(185, 15)
$rbKInsert.Size = New-Object System.Drawing.Size(60, 24)
$tabKey.Controls.Add($rbKInsert)

$lblKFind = New-Object System.Windows.Forms.Label
$lblKFind.Text = '查找(关键字):'
$lblKFind.Location = New-Object System.Drawing.Point(12, 55)
$lblKFind.Size = New-Object System.Drawing.Size(95, 20)
$tabKey.Controls.Add($lblKFind)

$txtKFind = New-Object System.Windows.Forms.TextBox
$txtKFind.Location = New-Object System.Drawing.Point(110, 52)
$txtKFind.Size = New-Object System.Drawing.Size(300, 24)
$tabKey.Controls.Add($txtKFind)

$lblKRep = New-Object System.Windows.Forms.Label
$lblKRep.Text = '替换为/插入内容:'
$lblKRep.Location = New-Object System.Drawing.Point(430, 55)
$lblKRep.Size = New-Object System.Drawing.Size(115, 20)
$tabKey.Controls.Add($lblKRep)

$txtKRep = New-Object System.Windows.Forms.TextBox
$txtKRep.Location = New-Object System.Drawing.Point(550, 52)
$txtKRep.Size = New-Object System.Drawing.Size(330, 24)
$tabKey.Controls.Add($txtKRep)

$lblKPos = New-Object System.Windows.Forms.Label
$lblKPos.Text = '插入位置:'
$lblKPos.Location = New-Object System.Drawing.Point(12, 95)
$lblKPos.Size = New-Object System.Drawing.Size(70, 20)
$tabKey.Controls.Add($lblKPos)

$numKPos = New-Object System.Windows.Forms.NumericUpDown
$numKPos.Location = New-Object System.Drawing.Point(85, 92)
$numKPos.Size = New-Object System.Drawing.Size(60, 24)
$numKPos.Minimum = 0
$numKPos.Maximum = 9999
$tabKey.Controls.Add($numKPos)

$rbKFromFront = New-Object System.Windows.Forms.RadioButton
$rbKFromFront.Text = '从前数'
$rbKFromFront.Location = New-Object System.Drawing.Point(155, 92)
$rbKFromFront.Size = New-Object System.Drawing.Size(75, 24)
$rbKFromFront.Checked = $true
$tabKey.Controls.Add($rbKFromFront)

$rbKFromEnd = New-Object System.Windows.Forms.RadioButton
$rbKFromEnd.Text = '从后数'
$rbKFromEnd.Location = New-Object System.Drawing.Point(235, 92)
$rbKFromEnd.Size = New-Object System.Drawing.Size(75, 24)
$tabKey.Controls.Add($rbKFromEnd)

$lblKHint = New-Object System.Windows.Forms.Label
$lblKHint.Text = '说明: 替换/删除按关键字字面匹配；增加将在指定位置插入"替换为/插入内容"的文本。'
$lblKHint.Location = New-Object System.Drawing.Point(12, 125)
$lblKHint.Size = New-Object System.Drawing.Size(870, 30)
$lblKHint.ForeColor = [System.Drawing.Color]::Gray
$tabKey.Controls.Add($lblKHint)

# === Tab 2: 指定位置字符 ===
$tabPos = New-Object System.Windows.Forms.TabPage
$tabPos.Text = '指定位置字符'
$tabMode.TabPages.Add($tabPos)

$lblPAct = New-Object System.Windows.Forms.Label
$lblPAct.Text = '操作:'
$lblPAct.Location = New-Object System.Drawing.Point(12, 18)
$lblPAct.Size = New-Object System.Drawing.Size(40, 20)
$tabPos.Controls.Add($lblPAct)

$rbPReplace = New-Object System.Windows.Forms.RadioButton
$rbPReplace.Text = '替换'
$rbPReplace.Location = New-Object System.Drawing.Point(55, 15)
$rbPReplace.Size = New-Object System.Drawing.Size(60, 24)
$rbPReplace.Checked = $true
$tabPos.Controls.Add($rbPReplace)

$rbPDelete = New-Object System.Windows.Forms.RadioButton
$rbPDelete.Text = '删除'
$rbPDelete.Location = New-Object System.Drawing.Point(120, 15)
$rbPDelete.Size = New-Object System.Drawing.Size(60, 24)
$tabPos.Controls.Add($rbPDelete)

$rbPInsert = New-Object System.Windows.Forms.RadioButton
$rbPInsert.Text = '增加'
$rbPInsert.Location = New-Object System.Drawing.Point(185, 15)
$rbPInsert.Size = New-Object System.Drawing.Size(60, 24)
$tabPos.Controls.Add($rbPInsert)

$lblPStart = New-Object System.Windows.Forms.Label
$lblPStart.Text = '起始位置(0=开头):'
$lblPStart.Location = New-Object System.Drawing.Point(12, 55)
$lblPStart.Size = New-Object System.Drawing.Size(120, 20)
$tabPos.Controls.Add($lblPStart)

$numPStart = New-Object System.Windows.Forms.NumericUpDown
$numPStart.Location = New-Object System.Drawing.Point(135, 52)
$numPStart.Size = New-Object System.Drawing.Size(60, 24)
$numPStart.Minimum = 0
$numPStart.Maximum = 9999
$tabPos.Controls.Add($numPStart)

$lblPLen = New-Object System.Windows.Forms.Label
$lblPLen.Text = '长度:'
$lblPLen.Location = New-Object System.Drawing.Point(210, 55)
$lblPLen.Size = New-Object System.Drawing.Size(40, 20)
$tabPos.Controls.Add($lblPLen)

$numPLen = New-Object System.Windows.Forms.NumericUpDown
$numPLen.Location = New-Object System.Drawing.Point(255, 52)
$numPLen.Size = New-Object System.Drawing.Size(60, 24)
$numPLen.Minimum = 0
$numPLen.Maximum = 9999
$numPLen.Value = 1
$tabPos.Controls.Add($numPLen)

$rbPFromFront = New-Object System.Windows.Forms.RadioButton
$rbPFromFront.Text = '从前数'
$rbPFromFront.Location = New-Object System.Drawing.Point(330, 52)
$rbPFromFront.Size = New-Object System.Drawing.Size(75, 24)
$rbPFromFront.Checked = $true
$tabPos.Controls.Add($rbPFromFront)

$rbPFromEnd = New-Object System.Windows.Forms.RadioButton
$rbPFromEnd.Text = '从后数'
$rbPFromEnd.Location = New-Object System.Drawing.Point(410, 52)
$rbPFromEnd.Size = New-Object System.Drawing.Size(75, 24)
$tabPos.Controls.Add($rbPFromEnd)

$lblPText = New-Object System.Windows.Forms.Label
$lblPText.Text = '替换为/插入内容:'
$lblPText.Location = New-Object System.Drawing.Point(12, 95)
$lblPText.Size = New-Object System.Drawing.Size(115, 20)
$tabPos.Controls.Add($lblPText)

$txtPText = New-Object System.Windows.Forms.TextBox
$txtPText.Location = New-Object System.Drawing.Point(135, 92)
$txtPText.Size = New-Object System.Drawing.Size(450, 24)
$tabPos.Controls.Add($txtPText)

$lblPHint = New-Object System.Windows.Forms.Label
$lblPHint.Text = '说明: 替换=用"内容"替换该位置的"长度"个字符；删除=移除该位置长度的字符；增加=在该位置插入"内容"(此时忽略长度)。'
$lblPHint.Location = New-Object System.Drawing.Point(12, 125)
$lblPHint.Size = New-Object System.Drawing.Size(870, 30)
$lblPHint.ForeColor = [System.Drawing.Color]::Gray
$tabPos.Controls.Add($lblPHint)

# === Tab 3: 格式匹配（通配符） ===
$tabPat = New-Object System.Windows.Forms.TabPage
$tabPat.Text = '格式匹配(通配符)'
$tabMode.TabPages.Add($tabPat)

$lblWAct = New-Object System.Windows.Forms.Label
$lblWAct.Text = '操作:'
$lblWAct.Location = New-Object System.Drawing.Point(12, 18)
$lblWAct.Size = New-Object System.Drawing.Size(40, 20)
$tabPat.Controls.Add($lblWAct)

$rbWReplace = New-Object System.Windows.Forms.RadioButton
$rbWReplace.Text = '替换'
$rbWReplace.Location = New-Object System.Drawing.Point(55, 15)
$rbWReplace.Size = New-Object System.Drawing.Size(60, 24)
$rbWReplace.Checked = $true
$tabPat.Controls.Add($rbWReplace)

$rbWDelete = New-Object System.Windows.Forms.RadioButton
$rbWDelete.Text = '删除'
$rbWDelete.Location = New-Object System.Drawing.Point(120, 15)
$rbWDelete.Size = New-Object System.Drawing.Size(60, 24)
$tabPat.Controls.Add($rbWDelete)

$rbWInsert = New-Object System.Windows.Forms.RadioButton
$rbWInsert.Text = '增加'
$rbWInsert.Location = New-Object System.Drawing.Point(185, 15)
$rbWInsert.Size = New-Object System.Drawing.Size(60, 24)
$tabPat.Controls.Add($rbWInsert)

$lblWFind = New-Object System.Windows.Forms.Label
$lblWFind.Text = '通配符模式:'
$lblWFind.Location = New-Object System.Drawing.Point(12, 55)
$lblWFind.Size = New-Object System.Drawing.Size(85, 20)
$tabPat.Controls.Add($lblWFind)

$txtWFind = New-Object System.Windows.Forms.TextBox
$txtWFind.Location = New-Object System.Drawing.Point(100, 52)
$txtWFind.Size = New-Object System.Drawing.Size(300, 24)
$tabPat.Controls.Add($txtWFind)

$lblWRep = New-Object System.Windows.Forms.Label
$lblWRep.Text = '替换为/插入:'
$lblWRep.Location = New-Object System.Drawing.Point(420, 55)
$lblWRep.Size = New-Object System.Drawing.Size(85, 20)
$tabPat.Controls.Add($lblWRep)

$txtWRep = New-Object System.Windows.Forms.TextBox
$txtWRep.Location = New-Object System.Drawing.Point(510, 52)
$txtWRep.Size = New-Object System.Drawing.Size(370, 24)
$tabPat.Controls.Add($txtWRep)

$lblWPos = New-Object System.Windows.Forms.Label
$lblWPos.Text = '插入位置:'
$lblWPos.Location = New-Object System.Drawing.Point(12, 95)
$lblWPos.Size = New-Object System.Drawing.Size(70, 20)
$tabPat.Controls.Add($lblWPos)

$numWPos = New-Object System.Windows.Forms.NumericUpDown
$numWPos.Location = New-Object System.Drawing.Point(85, 92)
$numWPos.Size = New-Object System.Drawing.Size(60, 24)
$numWPos.Minimum = 0
$numWPos.Maximum = 9999
$tabPat.Controls.Add($numWPos)

$rbWFromFront = New-Object System.Windows.Forms.RadioButton
$rbWFromFront.Text = '从前数'
$rbWFromFront.Location = New-Object System.Drawing.Point(155, 92)
$rbWFromFront.Size = New-Object System.Drawing.Size(75, 24)
$rbWFromFront.Checked = $true
$tabPat.Controls.Add($rbWFromFront)

$rbWFromEnd = New-Object System.Windows.Forms.RadioButton
$rbWFromEnd.Text = '从后数'
$rbWFromEnd.Location = New-Object System.Drawing.Point(235, 92)
$rbWFromEnd.Size = New-Object System.Drawing.Size(75, 24)
$tabPat.Controls.Add($rbWFromEnd)

$lblWHint = New-Object System.Windows.Forms.Label
$lblWHint.Text = '说明: * 匹配任意多个字符，? 匹配任意单个字符。例如: IMG_*_  / DSC?????.JPG'
$lblWHint.Location = New-Object System.Drawing.Point(12, 125)
$lblWHint.Size = New-Object System.Drawing.Size(870, 30)
$lblWHint.ForeColor = [System.Drawing.Color]::Gray
$tabPat.Controls.Add($lblWHint)

# ----- 操作按钮 + 预览 + 状态 -----
$pnlBtn = New-Object System.Windows.Forms.Panel
$pnlBtn.Location = New-Object System.Drawing.Point(10, 332)
$pnlBtn.Size = New-Object System.Drawing.Size(925, 38)
$pnlBtn.Anchor = 'Top, Left, Right'
$form.Controls.Add($pnlBtn)

$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Text = '预览'
$btnPreview.Location = New-Object System.Drawing.Point(0, 5)
$btnPreview.Size = New-Object System.Drawing.Size(120, 30)
$pnlBtn.Controls.Add($btnPreview)

$btnExecute = New-Object System.Windows.Forms.Button
$btnExecute.Text = '执行重命名'
$btnExecute.Location = New-Object System.Drawing.Point(130, 5)
$btnExecute.Size = New-Object System.Drawing.Size(140, 30)
$btnExecute.BackColor = [System.Drawing.Color]::FromArgb(220, 240, 220)
$pnlBtn.Controls.Add($btnExecute)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清空预览'
$btnClear.Location = New-Object System.Drawing.Point(280, 5)
$btnClear.Size = New-Object System.Drawing.Size(100, 30)
$pnlBtn.Controls.Add($btnClear)

$btnOpenLog = New-Object System.Windows.Forms.Button
$btnOpenLog.Text = '打开日志目录'
$btnOpenLog.Location = New-Object System.Drawing.Point(390, 5)
$btnOpenLog.Size = New-Object System.Drawing.Size(120, 30)
$pnlBtn.Controls.Add($btnOpenLog)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Text = '尚未预览'
$lblCount.Location = New-Object System.Drawing.Point(530, 12)
$lblCount.Size = New-Object System.Drawing.Size(390, 20)
$lblCount.ForeColor = [System.Drawing.Color]::DarkBlue
$pnlBtn.Controls.Add($lblCount)

# 预览 ListView
$grpPreview = New-Object System.Windows.Forms.GroupBox
$grpPreview.Text = '3. 预览 (执行前请先点击"预览"检查结果)'
$grpPreview.Location = New-Object System.Drawing.Point(10, 375)
$grpPreview.Size = New-Object System.Drawing.Size(925, 270)
$grpPreview.Anchor = 'Top, Bottom, Left, Right'
$form.Controls.Add($grpPreview)

$lvPreview = New-Object System.Windows.Forms.ListView
$lvPreview.Location = New-Object System.Drawing.Point(10, 22)
$lvPreview.Size = New-Object System.Drawing.Size(905, 215)
$lvPreview.Anchor = 'Top, Bottom, Left, Right'
$lvPreview.View = 'Details'
$lvPreview.FullRowSelect = $true
$lvPreview.GridLines = $true
[void]$lvPreview.Columns.Add('类型', 60)
[void]$lvPreview.Columns.Add('原文件名', 280)
[void]$lvPreview.Columns.Add('新文件名', 280)
[void]$lvPreview.Columns.Add('状态', 100)
[void]$lvPreview.Columns.Add('所在目录', 175)
$grpPreview.Controls.Add($lvPreview)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '就绪'
$lblStatus.Location = New-Object System.Drawing.Point(10, 240)
$lblStatus.Size = New-Object System.Drawing.Size(900, 20)
$lblStatus.Anchor = 'Bottom, Left, Right'
$lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
$grpPreview.Controls.Add($lblStatus)

# ------------------------------------------------------------
# 事件逻辑
# ------------------------------------------------------------

# 浏览文件夹
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '请选择要批量重命名的目标文件夹'
    if (-not [string]::IsNullOrWhiteSpace($txtFolder.Text) -and (Test-Path -LiteralPath $txtFolder.Text)) {
        $dlg.SelectedPath = $txtFolder.Text
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFolder.Text = $dlg.SelectedPath
    }
})

# 包含子文件夹复选 -> 启用深度
$chkRecursive.Add_CheckedChanged({
    $numDepth.Enabled = $chkRecursive.Checked
})

$btnClear.Add_Click({
    $lvPreview.Items.Clear()
    $script:PreviewItems.Clear()
    $lblCount.Text = '尚未预览'
    $lblStatus.Text = '已清空预览。'
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
})

$btnOpenLog.Add_Click({
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList $script:LogDir
})

# 收集 GUI 当前参数
function Get-CurrentParams {
    $itemType = if ($rbFile.Checked) { 'file' } elseif ($rbFolder.Checked) { 'folder' } else { 'both' }

    switch ($tabMode.SelectedIndex) {
        0 {
            $mode = 'keyword'
            $action = if ($rbKReplace.Checked) { 'replace' } elseif ($rbKDelete.Checked) { 'delete' } else { 'insert' }
            $p = @{
                Find       = $txtKFind.Text
                Replace    = $txtKRep.Text
                Position   = [int]$numKPos.Value
                Length     = 0
                FromEnd    = $rbKFromEnd.Checked
                IncludeExt = $chkIncludeExt.Checked
            }
        }
        1 {
            $mode = 'position'
            $action = if ($rbPReplace.Checked) { 'replace' } elseif ($rbPDelete.Checked) { 'delete' } else { 'insert' }
            $p = @{
                Find       = ''
                Replace    = $txtPText.Text
                Position   = [int]$numPStart.Value
                Length     = [int]$numPLen.Value
                FromEnd    = $rbPFromEnd.Checked
                IncludeExt = $chkIncludeExt.Checked
            }
        }
        default {
            $mode = 'pattern'
            $action = if ($rbWReplace.Checked) { 'replace' } elseif ($rbWDelete.Checked) { 'delete' } else { 'insert' }
            $p = @{
                Find       = $txtWFind.Text
                Replace    = $txtWRep.Text
                Position   = [int]$numWPos.Value
                Length     = 0
                FromEnd    = $rbWFromEnd.Checked
                IncludeExt = $chkIncludeExt.Checked
            }
        }
    }
    return @{
        ItemType  = $itemType
        Folder    = $txtFolder.Text
        Recursive = $chkRecursive.Checked
        Depth     = [int]$numDepth.Value
        Mode      = $mode
        Action    = $action
        Params    = $p
    }
}

# 预览
$btnPreview.Add_Click({
    $cfg = Get-CurrentParams
    if ([string]::IsNullOrWhiteSpace($cfg.Folder)) {
        [void][System.Windows.Forms.MessageBox]::Show('请先选择目标文件夹。','提示','OK','Information')
        return
    }
    if (-not (Test-Path -LiteralPath $cfg.Folder)) {
        [void][System.Windows.Forms.MessageBox]::Show('目标文件夹不存在。','提示','OK','Warning')
        return
    }

    $lblStatus.Text = '正在收集文件，请稍候...'
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
    $form.Refresh()

    $items = Get-TargetItems -Folder $cfg.Folder -Recursive $cfg.Recursive -Depth $cfg.Depth -ItemType $cfg.ItemType

    $lvPreview.BeginUpdate()
    $lvPreview.Items.Clear()
    $script:PreviewItems.Clear()

    $changeCnt = 0
    $skipCnt = 0
    $conflictCnt = 0
    # 用于检测同目录下的重名冲突
    $newPathSet = @{}

    foreach ($it in $items) {
        $isDir = $it.PSIsContainer
        $oldName = $it.Name
        $newName = Get-NewName -Name $oldName -IsFolder $isDir -Mode $cfg.Mode -Action $cfg.Action -P $cfg.Params

        # 校验非法字符
        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
        $hasInvalid = $false
        foreach ($c in $invalid) {
            if ($newName.IndexOf($c) -ge 0) { $hasInvalid = $true; break }
        }

        $status = ''
        if ([string]::IsNullOrWhiteSpace($newName)) {
            $status = '跳过(空名)'
            $skipCnt++
        } elseif ($newName -eq $oldName) {
            $status = '无变化'
            $skipCnt++
        } elseif ($hasInvalid) {
            $status = '非法字符'
            $skipCnt++
        } else {
            $parent = Split-Path -Parent $it.FullName
            $newFull = Join-Path $parent $newName
            $key = $newFull.ToLowerInvariant()
            if ($newPathSet.ContainsKey($key)) {
                $status = '同批次重名'
                $conflictCnt++
            } elseif ((Test-Path -LiteralPath $newFull) -and ($newFull -ne $it.FullName)) {
                $status = '目标已存在'
                $conflictCnt++
            } else {
                $status = '将重命名'
                $newPathSet[$key] = $true
                $changeCnt++
            }
        }

        $entry = @{
            FullName = $it.FullName
            OldName  = $oldName
            NewName  = $newName
            IsFolder = $isDir
            Status   = $status
            Parent   = (Split-Path -Parent $it.FullName)
        }
        [void]$script:PreviewItems.Add($entry)

        [string[]]$lvTexts = @(
            $(if ($isDir) { '文件夹' } else { '文件' }),
            $oldName,
            $newName,
            $status,
            (Split-Path -Parent $it.FullName)
        )
        $lvi = New-Object System.Windows.Forms.ListViewItem(,$lvTexts)
        switch ($status) {
            '将重命名'     { $lvi.ForeColor = [System.Drawing.Color]::DarkGreen }
            '无变化'       { $lvi.ForeColor = [System.Drawing.Color]::Gray }
            '跳过(空名)'   { $lvi.ForeColor = [System.Drawing.Color]::OrangeRed }
            '非法字符'     { $lvi.ForeColor = [System.Drawing.Color]::OrangeRed }
            '同批次重名'   { $lvi.ForeColor = [System.Drawing.Color]::Red }
            '目标已存在'   { $lvi.ForeColor = [System.Drawing.Color]::Red }
        }
        [void]$lvPreview.Items.Add($lvi)
    }

    $lvPreview.EndUpdate()
    $lblCount.Text = ("总计 {0} 项 | 将重命名 {1} | 跳过 {2} | 冲突 {3}" -f $items.Count, $changeCnt, $skipCnt, $conflictCnt)
    $lblStatus.Text = '预览完成。请检查结果，确认无误后点击"执行重命名"。'
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
})

# 执行
$btnExecute.Add_Click({
    if ($script:PreviewItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('请先点击"预览"。','提示','OK','Information')
        return
    }
    $toRename = @($script:PreviewItems | Where-Object { $_.Status -eq '将重命名' })
    if ($toRename.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('当前预览中没有需要重命名的项目。','提示','OK','Information')
        return
    }

    $msg = "即将对 {0} 个项目执行重命名，操作不可自动撤销。是否继续？" -f $toRename.Count
    $ret = [System.Windows.Forms.MessageBox]::Show($msg, '确认执行', 'YesNo', 'Warning')
    if ($ret -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logFile = Join-Path $script:LogDir ("rename_log_{0}.csv" -f $stamp)

    # 写 CSV 头（UTF8 BOM，便于 Excel 识别中文）
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $sw = New-Object System.IO.StreamWriter($logFile, $false, $utf8Bom)
    $sw.WriteLine('"时间","类型","原完整路径","原名称","新名称","新完整路径","状态","错误信息"')

    $okCnt = 0
    $failCnt = 0
    $lblStatus.Text = '正在执行重命名...'
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
    $form.Refresh()

    foreach ($entry in $script:PreviewItems) {
        if ($entry.Status -ne '将重命名') { continue }
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $typeName = if ($entry.IsFolder) { '文件夹' } else { '文件' }
        $parent  = $entry.Parent
        $oldFull = $entry.FullName
        $newFull = Join-Path $parent $entry.NewName
        $errMsg  = ''
        $stat    = '成功'
        try {
            if (-not (Test-Path -LiteralPath $oldFull)) {
                throw '源路径已不存在'
            }
            Rename-Item -LiteralPath $oldFull -NewName $entry.NewName -ErrorAction Stop
            $okCnt++
        } catch {
            $stat = '失败'
            $errMsg = $_.Exception.Message
            $failCnt++
        }

        $line = '"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}"' -f `
            $now,
            $typeName,
            ($oldFull       -replace '"','""'),
            ($entry.OldName -replace '"','""'),
            ($entry.NewName -replace '"','""'),
            ($newFull       -replace '"','""'),
            $stat,
            ($errMsg -replace '"','""')
        $sw.WriteLine($line)

        # 同步更新 ListView 状态
        for ($i = 0; $i -lt $lvPreview.Items.Count; $i++) {
            $row = $lvPreview.Items[$i]
            if ($row.SubItems[1].Text -eq $entry.OldName -and $row.SubItems[4].Text -eq $parent) {
                $row.SubItems[3].Text = $stat
                $row.ForeColor = if ($stat -eq '成功') { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Red }
                break
            }
        }
    }

    $sw.Flush()
    $sw.Close()
    $sw.Dispose()

    $lblCount.Text = ("执行完成: 成功 {0} | 失败 {1}" -f $okCnt, $failCnt)
    $lblStatus.Text = "操作记录已保存到: $logFile"
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen

    $sumMsg = "重命名完成。`r`n成功: {0}`r`n失败: {1}`r`n`r`n操作日志:`r`n{2}" -f $okCnt, $failCnt, $logFile
    [void][System.Windows.Forms.MessageBox]::Show($sumMsg, '执行结果', 'OK', 'Information')
})

# 启动
[void]$form.ShowDialog()
$form.Dispose()
