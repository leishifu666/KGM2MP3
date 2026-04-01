$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InputDir = Join-Path $BaseDir 'input'
$OutputDir = Join-Path $BaseDir 'output'
$ToolsDir = Join-Path $BaseDir 'tools'
$LogsDir = Join-Path $BaseDir 'logs'

foreach ($path in @($InputDir, $OutputDir, $ToolsDir, $LogsDir)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Find-KuGouDb {
    $candidates = @(
        (Join-Path $env:APPDATA 'Kugou8\KGMusicV3.db'),
        'C:\Users\Administrator\AppData\Roaming\Kugou8\KGMusicV3.db'
    ) | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Find-InfraDll {
    $candidates = @(
        (Join-Path $ToolsDir 'infra.dll'),
        'D:\KGMusic\20.1.01.27691\infra.dll',
        'D:\KGMusic\infra.dll',
        'C:\Program Files\KuGou\infra.dll',
        'C:\Program Files (x86)\KuGou\infra.dll'
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Ensure-Tools {
    $status = [ordered]@{
        kggDec   = Test-Path -LiteralPath (Join-Path $ToolsDir 'kgg-dec.exe')
        unlock64 = Test-Path -LiteralPath (Join-Path $ToolsDir 'unlockKuGoWin-64.exe')
        ffmpeg   = Test-Path -LiteralPath (Join-Path $ToolsDir 'ffmpeg.exe')
        kgmMask  = Test-Path -LiteralPath (Join-Path $ToolsDir 'kgm.mask')
        infra    = Test-Path -LiteralPath (Join-Path $ToolsDir 'infra.dll')
        ncmdump  = Test-Path -LiteralPath (Join-Path $ToolsDir 'ncmdump.exe')
        kugouDb  = [bool](Find-KuGouDb)
    }

    if (-not $status.infra) {
        $infraPath = Find-InfraDll
        if ($infraPath) {
            Copy-Item -LiteralPath $infraPath -Destination (Join-Path $ToolsDir 'infra.dll') -Force
            $status.infra = $true
        }
    }

    return $status
}

function Get-Mp3QualityConfig {
    param([string]$Preset)

    switch ($Preset) {
        '标准' {
            return [pscustomobject]@{
                Label = '标准'
                Args  = @('-codec:a', 'libmp3lame', '-q:a', '2')
            }
        }
        '省空间' {
            return [pscustomobject]@{
                Label = '省空间'
                Args  = @('-codec:a', 'libmp3lame', '-b:a', '128k')
            }
        }
        default {
            return [pscustomobject]@{
                Label = '高质量'
                Args  = @('-codec:a', 'libmp3lame', '-q:a', '0')
            }
        }
    }
}

function Convert-AudioFiles {
    param(
        [string[]]$SourcePaths,
        [string]$QualityPreset = '高质量'
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile = Join-Path $LogsDir ("run-$timestamp.log")
    $workDir = Join-Path $BaseDir ("work-$timestamp")
    $workOut = Join-Path $workDir 'kgm-vpr-out'

    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    New-Item -ItemType Directory -Path $workOut -Force | Out-Null

    $kggDec = Join-Path $ToolsDir 'kgg-dec.exe'
    $unlock64 = Join-Path $ToolsDir 'unlockKuGoWin-64.exe'
    $ffmpeg = Join-Path $ToolsDir 'ffmpeg.exe'
    $kgmMask = Join-Path $ToolsDir 'kgm.mask'
    $infra = Join-Path $ToolsDir 'infra.dll'
    $ncmdump = Join-Path $ToolsDir 'ncmdump.exe'
    $db = Find-KuGouDb
    $qualityConfig = Get-Mp3QualityConfig -Preset $QualityPreset

    if (-not (Test-Path -LiteralPath $kggDec)) { throw 'Missing kgg-dec.exe' }
    if (-not (Test-Path -LiteralPath $unlock64)) { throw 'Missing unlockKuGoWin-64.exe' }
    if (-not (Test-Path -LiteralPath $ffmpeg)) { throw 'Missing ffmpeg.exe' }
    if (-not (Test-Path -LiteralPath $kgmMask)) { throw 'Missing kgm.mask' }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('[信息] 开始转换')
    $lines.Add('[信息] 输出质量：' + $qualityConfig.Label)

    Copy-Item -LiteralPath $kggDec -Destination (Join-Path $workDir 'kgg-dec.exe') -Force
    Copy-Item -LiteralPath $unlock64 -Destination (Join-Path $workDir 'unlockKuGoWin-64.exe') -Force
    Copy-Item -LiteralPath $kgmMask -Destination (Join-Path $workDir 'kgm.mask') -Force
    Copy-Item -LiteralPath $ffmpeg -Destination (Join-Path $workOut 'ffmpeg.exe') -Force

    if (Test-Path -LiteralPath $infra) {
        Copy-Item -LiteralPath $infra -Destination (Join-Path $workDir 'infra.dll') -Force
    }
    if (Test-Path -LiteralPath $ncmdump) {
        Copy-Item -LiteralPath $ncmdump -Destination (Join-Path $workDir 'ncmdump.exe') -Force
    }

    foreach ($src in $SourcePaths) {
        if (Test-Path -LiteralPath $src) {
            $name = [System.IO.Path]::GetFileName($src)
            $inputTarget = Join-Path $InputDir $name
            $workTarget = Join-Path $workDir $name
            if ([System.IO.Path]::GetFullPath($src) -ne [System.IO.Path]::GetFullPath($inputTarget)) {
                Copy-Item -LiteralPath $src -Destination $inputTarget -Force
            }
            Copy-Item -LiteralPath $src -Destination $workTarget -Force
            $lines.Add('[信息] 已添加文件：' + $src)
        }
    }

    Push-Location $workDir
    try {
        $kggFiles = @(Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.kgg' })
        if ($kggFiles.Count -gt 0) {
            if ($db) {
                foreach ($file in $kggFiles) {
                    $lines.Add('[信息] 正在解码 KGG：' + $file.Name)
                    $previousPreference = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'
                        $result = & (Join-Path $workDir 'kgg-dec.exe') --db $db -- $file.FullName 2>&1 | Out-String
                        $exitCode = $LASTEXITCODE
                    }
                    finally {
                        $ErrorActionPreference = $previousPreference
                    }
                    if ($result) {
                        foreach ($line in ($result.Trim() -split "`r?`n")) {
                            if ($line) { $lines.Add($line) }
                        }
                    }
                    if ($exitCode -ne 0) {
                        $lines.Add('[警告] kgg-dec 退出码：' + $exitCode)
                    }
                }
            }
            else {
                $lines.Add('[警告] 未找到 KGMusicV3.db，已跳过 KGG 解码。')
            }
        }

        $kgmFiles = @(Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.kgm', '.kgma') })
        if ($kgmFiles.Count -gt 0) {
            $lines.Add('[信息] 正在处理 KGM/KGMA，数量：' + $kgmFiles.Count)
            $result = cmd /c "echo.|`"$(Join-Path $workDir 'unlockKuGoWin-64.exe')`"" 2>&1 | Out-String
            if ($result) {
                foreach ($line in ($result.Trim() -split "`r?`n")) {
                    if ($line) { $lines.Add($line) }
                }
            }
        }

        $ncmFiles = @(Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.ncm' })
        if ($ncmFiles.Count -gt 0) {
            if (-not (Test-Path -LiteralPath (Join-Path $workDir 'ncmdump.exe'))) {
                $lines.Add('[警告] 检测到 NCM 文件，但 tools 中缺少 ncmdump.exe，已跳过 NCM 转换。')
            }
            else {
                $lines.Add('[信息] 正在处理 NCM，数量：' + $ncmFiles.Count)
                $previousPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    $result = & (Join-Path $workDir 'ncmdump.exe') -o $workDir -- @($ncmFiles | Select-Object -ExpandProperty FullName) 2>&1 | Out-String
                    $exitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $previousPreference
                }
                if ($result) {
                    foreach ($line in ($result.Trim() -split "`r?`n")) {
                        if ($line) { $lines.Add($line) }
                    }
                }
                if ($exitCode -ne 0) {
                    $lines.Add('[警告] ncmdump 退出码：' + $exitCode)
                }
            }
        }

        $rootFlacs = @(Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*_kgg-dec.flac' -or $_.Extension -eq '.flac' })
        foreach ($file in $rootFlacs) {
            $baseName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            if ($baseName.EndsWith('_kgg-dec')) {
                $baseName = $baseName.Substring(0, $baseName.Length - 8)
            }
            $dst = Join-Path $OutputDir ($baseName + '.mp3')
            $lines.Add('[信息] 正在转换为 MP3：' + $file.Name)
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & $ffmpeg -y -i $file.FullName @($qualityConfig.Args) -map_metadata 0 $dst 2>&1 | Out-Null
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousPreference
            }
            if ($exitCode -ne 0) {
                $lines.Add('[警告] ffmpeg 退出码：' + $exitCode)
            }
        }

        $outFlacs = @(Get-ChildItem -LiteralPath $workOut -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.flac' })
        foreach ($file in $outFlacs) {
            $dst = Join-Path $OutputDir ($file.BaseName + '.mp3')
            $lines.Add('[信息] 正在转换为 MP3：' + $file.Name)
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & $ffmpeg -y -i $file.FullName @($qualityConfig.Args) -map_metadata 0 $dst 2>&1 | Out-Null
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousPreference
            }
            if ($exitCode -ne 0) {
                $lines.Add('[警告] ffmpeg 退出码：' + $exitCode)
            }
        }

        $ncmMp3Files = @(Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.mp3' })
        foreach ($file in $ncmMp3Files) {
            $dst = Join-Path $OutputDir $file.Name
            if ([System.IO.Path]::GetFullPath($file.FullName) -ne [System.IO.Path]::GetFullPath($dst)) {
                Copy-Item -LiteralPath $file.FullName -Destination $dst -Force
                $lines.Add('[信息] 已输出 NCM 生成的 MP3：' + $file.Name)
            }
        }
    }
    finally {
        Pop-Location
    }

    $mp3Files = @(Get-ChildItem -LiteralPath $OutputDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.mp3' })
    if ($mp3Files.Count -eq 0) {
        $lines.Add('[警告] 没有生成 MP3 文件。')
        $lines.Add('[警告] 如果 KGG 提示 ekey 或 key not found，请在本机酷狗重新下载歌曲后再试。')
    }
    else {
        $lines.Add('[信息] 已生成 MP3 数量：' + $mp3Files.Count)
    }

    Set-Content -LiteralPath $logFile -Value ($lines -join [Environment]::NewLine) -Encoding UTF8

    return [pscustomobject]@{
        logFile   = $logFile
        outputDir = $OutputDir
        mp3Count  = $mp3Files.Count
        files     = @($mp3Files | Select-Object -ExpandProperty Name)
        messages  = $lines
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = '酷狗音频一键转 MP3'
$form.Size = New-Object System.Drawing.Size(860, 680)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::White
$form.ForeColor = [System.Drawing.Color]::Black
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = '酷狗音频一键转 MP3'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 15)
$title.AutoSize = $true
$form.Controls.Add($title)

$desc = New-Object System.Windows.Forms.Label
$desc.Text = '选择 kgg / kgm / kgma / flac / ncm 文件，一键转换成 mp3。'
$desc.Location = New-Object System.Drawing.Point(22, 50)
$desc.AutoSize = $true
$form.Controls.Add($desc)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = 'Vertical'
$statusBox.Location = New-Object System.Drawing.Point(20, 90)
$statusBox.Size = New-Object System.Drawing.Size(390, 150)
$statusBox.BackColor = [System.Drawing.Color]::WhiteSmoke
$statusBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($statusBox)

$qualityLabel = New-Object System.Windows.Forms.Label
$qualityLabel.Text = '输出质量：'
$qualityLabel.Location = New-Object System.Drawing.Point(20, 250)
$qualityLabel.AutoSize = $true
$form.Controls.Add($qualityLabel)

$qualityCombo = New-Object System.Windows.Forms.ComboBox
$qualityCombo.Location = New-Object System.Drawing.Point(95, 246)
$qualityCombo.Size = New-Object System.Drawing.Size(140, 28)
$qualityCombo.DropDownStyle = 'DropDownList'
[void]$qualityCombo.Items.Add('高质量')
[void]$qualityCombo.Items.Add('标准')
[void]$qualityCombo.Items.Add('省空间')
$qualityCombo.SelectedIndex = 0
$form.Controls.Add($qualityCombo)

$fileList = New-Object System.Windows.Forms.ListBox
$fileList.Location = New-Object System.Drawing.Point(20, 280)
$fileList.Size = New-Object System.Drawing.Size(390, 280)
$fileList.BackColor = [System.Drawing.Color]::WhiteSmoke
$form.Controls.Add($fileList)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(430, 90)
$logBox.Size = New-Object System.Drawing.Size(390, 470)
$logBox.BackColor = [System.Drawing.Color]::WhiteSmoke
$logBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($logBox)

$resultLabel = New-Object System.Windows.Forms.Label
$resultLabel.Text = '准备就绪。'
$resultLabel.Location = New-Object System.Drawing.Point(250, 250)
$resultLabel.AutoSize = $true
$form.Controls.Add($resultLabel)

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = '选择文件'
$btnPick.Location = New-Object System.Drawing.Point(20, 585)
$btnPick.Size = New-Object System.Drawing.Size(110, 36)
$form.Controls.Add($btnPick)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清空列表'
$btnClear.Location = New-Object System.Drawing.Point(140, 585)
$btnClear.Size = New-Object System.Drawing.Size(110, 36)
$form.Controls.Add($btnClear)

$btnConvert = New-Object System.Windows.Forms.Button
$btnConvert.Text = '开始转换'
$btnConvert.Location = New-Object System.Drawing.Point(260, 585)
$btnConvert.Size = New-Object System.Drawing.Size(120, 36)
$form.Controls.Add($btnConvert)

$btnOutput = New-Object System.Windows.Forms.Button
$btnOutput.Text = '打开 output'
$btnOutput.Location = New-Object System.Drawing.Point(430, 585)
$btnOutput.Size = New-Object System.Drawing.Size(120, 36)
$form.Controls.Add($btnOutput)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = '打开 logs'
$btnLogs.Location = New-Object System.Drawing.Point(560, 585)
$btnLogs.Size = New-Object System.Drawing.Size(120, 36)
$form.Controls.Add($btnLogs)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新状态'
$btnRefresh.Location = New-Object System.Drawing.Point(690, 585)
$btnRefresh.Size = New-Object System.Drawing.Size(130, 36)
$form.Controls.Add($btnRefresh)

$selectedFiles = New-Object 'System.Collections.Generic.List[string]'

function Refresh-StatusView {
    $status = Ensure-Tools
    $dbPath = Find-KuGouDb
    $statusBox.Text = @(
        '环境状态',
        ('kgg-dec.exe        ：' + $(if ($status.kggDec) { '已就绪' } else { '缺失' })),
        ('unlockKuGoWin-64  ：' + $(if ($status.unlock64) { '已就绪' } else { '缺失' })),
        ('ffmpeg.exe         ：' + $(if ($status.ffmpeg) { '已就绪' } else { '缺失' })),
        ('kgm.mask           ：' + $(if ($status.kgmMask) { '已就绪' } else { '缺失' })),
        ('infra.dll          ：' + $(if ($status.infra) { '已就绪' } else { '缺失' })),
        ('ncmdump.exe        ：' + $(if ($status.ncmdump) { '已就绪' } else { '缺失' })),
        ('KGMusicV3.db       ：' + $(if ($status.kugouDb) { '已找到' } else { '未找到' })),
        '',
        ('数据库路径         ：' + $(if ($dbPath) { $dbPath } else { '未检测到' })),
        '',
        ('output 目录        ：' + $OutputDir),
        ('logs 目录          ：' + $LogsDir)
    ) -join [Environment]::NewLine
}

Refresh-StatusView

$btnPick.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Filter = '音频文件|*.kgg;*.kgm;*.kgma;*.flac;*.ncm'
    $dialog.Title = '选择音频文件'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($file in $dialog.FileNames) {
            if (-not $selectedFiles.Contains($file)) {
                $selectedFiles.Add($file)
                [void]$fileList.Items.Add($file)
            }
        }
        $resultLabel.Text = '已选择文件：' + $selectedFiles.Count
    }
})

$btnClear.Add_Click({
    $selectedFiles.Clear()
    $fileList.Items.Clear()
    $logBox.Clear()
    $resultLabel.Text = '准备就绪。'
    $qualityCombo.SelectedIndex = 0
})

$btnOutput.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList $OutputDir | Out-Null })
$btnLogs.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList $LogsDir | Out-Null })
$btnRefresh.Add_Click({ Refresh-StatusView; $resultLabel.Text = '状态已刷新。' })

$btnConvert.Add_Click({
    if ($selectedFiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先选择至少一个文件。', '未选择文件') | Out-Null
        return
    }

    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnConvert.Enabled = $false
        $resultLabel.Text = '正在转换...'
        $logBox.Text = '正在执行转换，请稍候...' + [Environment]::NewLine

        $result = Convert-AudioFiles -SourcePaths @($selectedFiles.ToArray()) -QualityPreset $qualityCombo.SelectedItem.ToString()
        $logBox.Text = ($result.messages -join [Environment]::NewLine)
        $resultLabel.Text = '转换完成，MP3 数量：' + $result.mp3Count

        if ($result.mp3Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show('转换完成，MP3 文件已输出到 output 文件夹。', '完成') | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show('没有生成 MP3 文件，请查看日志了解详情。', '转换完成但有警告') | Out-Null
        }
    }
    catch {
        $logBox.Text += '[错误] ' + $_.Exception.Message + [Environment]::NewLine
        $resultLabel.Text = '转换失败。'
        [System.Windows.Forms.MessageBox]::Show('转换失败：' + $_.Exception.Message, '错误') | Out-Null
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnConvert.Enabled = $true
    }
})

if (-not $env:KUGOU_HEADLESS) {
    [void]$form.ShowDialog()
}
