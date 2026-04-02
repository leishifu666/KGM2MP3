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

function Get-OutputFormatConfig {
    param(
        [string]$Format,
        [string]$QualityPreset
    )

    switch ($Format) {
        'WAV' {
            return [pscustomobject]@{
                Label = 'WAV'
                Extension = '.wav'
                Args = @('-codec:a', 'pcm_s16le')
                SupportsQuality = $false
            }
        }
        'FLAC' {
            return [pscustomobject]@{
                Label = 'FLAC'
                Extension = '.flac'
                Args = @('-codec:a', 'flac')
                SupportsQuality = $false
            }
        }
        'M4A' {
            return [pscustomobject]@{
                Label = 'M4A'
                Extension = '.m4a'
                Args = @('-codec:a', 'aac', '-b:a', '192k')
                SupportsQuality = $false
            }
        }
        'OGG' {
            return [pscustomobject]@{
                Label = 'OGG'
                Extension = '.ogg'
                Args = @('-codec:a', 'libvorbis', '-q:a', '5')
                SupportsQuality = $false
            }
        }
        'OPUS' {
            return [pscustomobject]@{
                Label = 'OPUS'
                Extension = '.opus'
                Args = @('-codec:a', 'libopus', '-b:a', '160k', '-vbr', 'on')
                SupportsQuality = $false
            }
        }
        'WMA' {
            return [pscustomobject]@{
                Label = 'WMA'
                Extension = '.wma'
                Args = @('-codec:a', 'wmav2', '-b:a', '192k')
                SupportsQuality = $false
            }
        }
        default {
            $mp3Quality = Get-Mp3QualityConfig -Preset $QualityPreset
            return [pscustomobject]@{
                Label = 'MP3'
                Extension = '.mp3'
                Args = $mp3Quality.Args
                SupportsQuality = $true
            }
        }
    }
}

function Get-ConvertibleAudioExtensions {
    return @('.mp3', '.wav', '.aac', '.m4a', '.flac', '.ogg', '.wma', '.opus')
}

function Get-NormalizedBaseName {
    param([System.IO.FileInfo]$File)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($File.Name)
    if ($baseName.EndsWith('_kgg-dec')) {
        $baseName = $baseName.Substring(0, $baseName.Length - 8)
    }

    return $baseName
}

function Convert-AudioFiles {
    param(
        [string[]]$SourcePaths,
        [string]$QualityPreset = '高质量',
        [string]$OutputFormat = 'MP3'
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
    $outputConfig = Get-OutputFormatConfig -Format $OutputFormat -QualityPreset $QualityPreset
    $convertibleExtensions = Get-ConvertibleAudioExtensions

    if (-not (Test-Path -LiteralPath $kggDec)) { throw 'Missing kgg-dec.exe' }
    if (-not (Test-Path -LiteralPath $unlock64)) { throw 'Missing unlockKuGoWin-64.exe' }
    if (-not (Test-Path -LiteralPath $ffmpeg)) { throw 'Missing ffmpeg.exe' }
    if (-not (Test-Path -LiteralPath $kgmMask)) { throw 'Missing kgm.mask' }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $generatedOutputs = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('[信息] 开始转换')
    $lines.Add('[信息] 输出格式：' + $outputConfig.Label)
    if ($outputConfig.SupportsQuality) {
        $lines.Add('[信息] 输出质量：' + $QualityPreset)
    }
    else {
        $lines.Add('[信息] 当前输出格式不使用质量档位，已按固定参数导出。')
    }

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

        $audioFiles = @()
        $audioFiles += @(Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue | Where-Object { $convertibleExtensions -contains $_.Extension.ToLower() })
        $audioFiles += @(Get-ChildItem -LiteralPath $workOut -File -ErrorAction SilentlyContinue | Where-Object { $convertibleExtensions -contains $_.Extension.ToLower() })
        $audioFiles = @($audioFiles | Sort-Object FullName -Unique)

        foreach ($file in $audioFiles) {
            $baseName = Get-NormalizedBaseName -File $file
            $dst = Join-Path $OutputDir ($baseName + $outputConfig.Extension)

            if ($file.Extension.ToLower() -eq $outputConfig.Extension.ToLower()) {
                if ([System.IO.Path]::GetFullPath($file.FullName) -ne [System.IO.Path]::GetFullPath($dst)) {
                    Copy-Item -LiteralPath $file.FullName -Destination $dst -Force
                }
                if (Test-Path -LiteralPath $dst) {
                    $generatedOutputs.Add($dst)
                }
                $lines.Add('[信息] 已直接输出：' + $file.Name)
                continue
            }

            $lines.Add('[信息] 正在转换为 ' + $outputConfig.Label + '：' + $file.Name)
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & $ffmpeg -y -i $file.FullName -map 0:a:0 @($outputConfig.Args) -map_metadata 0 $dst 2>&1 | Out-Null
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousPreference
            }
            if ($exitCode -ne 0) {
                $lines.Add('[警告] ffmpeg 退出码：' + $exitCode)
            }
            elseif (Test-Path -LiteralPath $dst) {
                $generatedOutputs.Add($dst)
            }
        }
    }
    finally {
        Pop-Location
    }

    $outputFiles = @($generatedOutputs | Sort-Object -Unique)
    if ($outputFiles.Count -eq 0) {
        $lines.Add('[警告] 没有生成 ' + $outputConfig.Label + ' 文件。')
        $lines.Add('[警告] 如果 KGG 提示 ekey 或 key not found，请在本机酷狗重新下载歌曲后再试。')
    }
    else {
        $lines.Add('[信息] 已生成 ' + $outputConfig.Label + ' 数量：' + $outputFiles.Count)
    }

    Set-Content -LiteralPath $logFile -Value ($lines -join [Environment]::NewLine) -Encoding UTF8

    return [pscustomobject]@{
        logFile      = $logFile
        outputDir    = $OutputDir
        outputCount  = $outputFiles.Count
        outputFormat = $outputConfig.Label
        files        = @($outputFiles | ForEach-Object { [System.IO.Path]::GetFileName($_) })
        messages     = $lines
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = '音频一键转换工具'
$form.Size = New-Object System.Drawing.Size(860, 680)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::White
$form.ForeColor = [System.Drawing.Color]::Black
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = '音频一键转换工具'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 15)
$title.AutoSize = $true
$form.Controls.Add($title)

$desc = New-Object System.Windows.Forms.Label
$desc.Text = '添加文件、选择输出格式，然后一键开始转换。'
$desc.Location = New-Object System.Drawing.Point(22, 50)
$desc.AutoSize = $true
$form.Controls.Add($desc)

$inputFormatsLabel = New-Object System.Windows.Forms.Label
$inputFormatsLabel.Text = '支持输入：KGG / KGM / KGMA / NCM / MP3 / WAV / AAC / M4A / FLAC / OGG / WMA / OPUS'
$inputFormatsLabel.Location = New-Object System.Drawing.Point(22, 72)
$inputFormatsLabel.AutoSize = $true
$inputFormatsLabel.ForeColor = [System.Drawing.Color]::DarkBlue
$form.Controls.Add($inputFormatsLabel)

$envLabel = New-Object System.Windows.Forms.Label
$envLabel.Text = '环境检查'
$envLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
$envLabel.Location = New-Object System.Drawing.Point(20, 104)
$envLabel.AutoSize = $true
$form.Controls.Add($envLabel)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = 'Vertical'
$statusBox.Location = New-Object System.Drawing.Point(20, 126)
$statusBox.Size = New-Object System.Drawing.Size(390, 104)
$statusBox.BackColor = [System.Drawing.Color]::WhiteSmoke
$statusBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($statusBox)

$settingsLabel = New-Object System.Windows.Forms.Label
$settingsLabel.Text = '转换设置'
$settingsLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
$settingsLabel.Location = New-Object System.Drawing.Point(20, 240)
$settingsLabel.AutoSize = $true
$form.Controls.Add($settingsLabel)

$qualityLabel = New-Object System.Windows.Forms.Label
$qualityLabel.Text = '输出质量：'
$qualityLabel.Location = New-Object System.Drawing.Point(20, 268)
$qualityLabel.AutoSize = $true
$form.Controls.Add($qualityLabel)

$qualityCombo = New-Object System.Windows.Forms.ComboBox
$qualityCombo.Location = New-Object System.Drawing.Point(95, 264)
$qualityCombo.Size = New-Object System.Drawing.Size(130, 28)
$qualityCombo.DropDownStyle = 'DropDownList'
[void]$qualityCombo.Items.Add('高质量')
[void]$qualityCombo.Items.Add('标准')
[void]$qualityCombo.Items.Add('省空间')
$qualityCombo.SelectedIndex = 0
$form.Controls.Add($qualityCombo)

$outputFormatLabel = New-Object System.Windows.Forms.Label
$outputFormatLabel.Text = '输出格式：'
$outputFormatLabel.Location = New-Object System.Drawing.Point(235, 268)
$outputFormatLabel.AutoSize = $true
$form.Controls.Add($outputFormatLabel)

$outputFormatCombo = New-Object System.Windows.Forms.ComboBox
$outputFormatCombo.Location = New-Object System.Drawing.Point(310, 264)
$outputFormatCombo.Size = New-Object System.Drawing.Size(100, 28)
$outputFormatCombo.DropDownStyle = 'DropDownList'
[void]$outputFormatCombo.Items.Add('MP3')
[void]$outputFormatCombo.Items.Add('WAV')
[void]$outputFormatCombo.Items.Add('FLAC')
[void]$outputFormatCombo.Items.Add('M4A')
[void]$outputFormatCombo.Items.Add('OGG')
[void]$outputFormatCombo.Items.Add('OPUS')
[void]$outputFormatCombo.Items.Add('WMA')
$outputFormatCombo.SelectedIndex = 0
$form.Controls.Add($outputFormatCombo)

$qualityHintLabel = New-Object System.Windows.Forms.Label
$qualityHintLabel.Text = '质量档位仅对 MP3 输出生效。'
$qualityHintLabel.Location = New-Object System.Drawing.Point(20, 298)
$qualityHintLabel.AutoSize = $true
$qualityHintLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($qualityHintLabel)

$filesLabel = New-Object System.Windows.Forms.Label
$filesLabel.Text = '待处理文件'
$filesLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
$filesLabel.Location = New-Object System.Drawing.Point(20, 326)
$filesLabel.AutoSize = $true
$form.Controls.Add($filesLabel)

$fileCountLabel = New-Object System.Windows.Forms.Label
$fileCountLabel.Text = '共 0 个文件'
$fileCountLabel.Location = New-Object System.Drawing.Point(330, 326)
$fileCountLabel.AutoSize = $true
$fileCountLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($fileCountLabel)

$fileList = New-Object System.Windows.Forms.ListBox
$fileList.Location = New-Object System.Drawing.Point(20, 350)
$fileList.Size = New-Object System.Drawing.Size(390, 210)
$fileList.BackColor = [System.Drawing.Color]::WhiteSmoke
$fileList.SelectionMode = 'MultiExtended'
$form.Controls.Add($fileList)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Text = '结果摘要'
$summaryLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
$summaryLabel.Location = New-Object System.Drawing.Point(430, 88)
$summaryLabel.AutoSize = $true
$form.Controls.Add($summaryLabel)

$summaryBox = New-Object System.Windows.Forms.TextBox
$summaryBox.Multiline = $true
$summaryBox.ReadOnly = $true
$summaryBox.Location = New-Object System.Drawing.Point(430, 110)
$summaryBox.Size = New-Object System.Drawing.Size(390, 95)
$summaryBox.BackColor = [System.Drawing.Color]::WhiteSmoke
$summaryBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($summaryBox)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = '处理日志'
$logLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
$logLabel.Location = New-Object System.Drawing.Point(430, 215)
$logLabel.AutoSize = $true
$form.Controls.Add($logLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(430, 237)
$logBox.Size = New-Object System.Drawing.Size(390, 323)
$logBox.BackColor = [System.Drawing.Color]::WhiteSmoke
$logBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($logBox)

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = '添加文件'
$btnPick.Location = New-Object System.Drawing.Point(20, 585)
$btnPick.Size = New-Object System.Drawing.Size(95, 36)
$form.Controls.Add($btnPick)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = '移除选中'
$btnRemove.Location = New-Object System.Drawing.Point(125, 585)
$btnRemove.Size = New-Object System.Drawing.Size(105, 36)
$form.Controls.Add($btnRemove)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清空列表'
$btnClear.Location = New-Object System.Drawing.Point(240, 585)
$btnClear.Size = New-Object System.Drawing.Size(95, 36)
$form.Controls.Add($btnClear)

$btnConvert = New-Object System.Windows.Forms.Button
$btnConvert.Text = '开始转换'
$btnConvert.Location = New-Object System.Drawing.Point(345, 585)
$btnConvert.Size = New-Object System.Drawing.Size(105, 36)
$form.Controls.Add($btnConvert)

$btnOutput = New-Object System.Windows.Forms.Button
$btnOutput.Text = '打开输出目录'
$btnOutput.Location = New-Object System.Drawing.Point(460, 585)
$btnOutput.Size = New-Object System.Drawing.Size(110, 36)
$form.Controls.Add($btnOutput)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = '打开日志目录'
$btnLogs.Location = New-Object System.Drawing.Point(580, 585)
$btnLogs.Size = New-Object System.Drawing.Size(105, 36)
$form.Controls.Add($btnLogs)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新环境状态'
$btnRefresh.Location = New-Object System.Drawing.Point(695, 585)
$btnRefresh.Size = New-Object System.Drawing.Size(125, 36)
$form.Controls.Add($btnRefresh)

$selectedFiles = New-Object 'System.Collections.Generic.List[string]'

function Update-OutputControls {
    $isMp3 = $outputFormatCombo.SelectedItem.ToString() -eq 'MP3'
    $qualityCombo.Enabled = $isMp3
    $qualityLabel.Enabled = $isMp3
    if ($isMp3) {
        $qualityHintLabel.Text = '质量档位仅对 MP3 输出生效。'
    }
    else {
        $qualityHintLabel.Text = '当前输出格式使用固定参数导出。'
    }
}

function Update-FileActionState {
    $hasFiles = $selectedFiles.Count -gt 0
    $hasSelection = $fileList.SelectedItems.Count -gt 0
    $btnConvert.Enabled = $hasFiles
    $btnClear.Enabled = $hasFiles
    $btnRemove.Enabled = $hasSelection
}

function Set-BusyState {
    param([bool]$IsBusy)

    $btnPick.Enabled = -not $IsBusy
    $btnRemove.Enabled = (-not $IsBusy) -and ($fileList.SelectedItems.Count -gt 0)
    $btnClear.Enabled = (-not $IsBusy) -and ($selectedFiles.Count -gt 0)
    $btnConvert.Enabled = (-not $IsBusy) -and ($selectedFiles.Count -gt 0)
    $btnOutput.Enabled = -not $IsBusy
    $btnLogs.Enabled = -not $IsBusy
    $btnRefresh.Enabled = -not $IsBusy
    $outputFormatCombo.Enabled = -not $IsBusy
    if (-not $IsBusy) {
        Update-OutputControls
    }
    else {
        $qualityCombo.Enabled = $false
        $qualityLabel.Enabled = $false
    }
}

function Update-ResultSummary {
    param(
        [string]$StatusText,
        [string[]]$Details = @()
    )

    $summaryBox.Text = @($StatusText) + $Details -join [Environment]::NewLine
}

function Refresh-StatusView {
    $status = Ensure-Tools
    $dbPath = Find-KuGouDb
    $statusBox.Text = @(
        '环境状态',
        ('kgg-dec.exe        ：' + $(if ($status.kggDec) { '已就绪' } else { '缺失，KGG 转换将不可用' })),
        ('unlockKuGoWin-64  ：' + $(if ($status.unlock64) { '已就绪' } else { '缺失，KGM/KGMA 转换将不可用' })),
        ('ffmpeg.exe         ：' + $(if ($status.ffmpeg) { '已就绪' } else { '缺失，多格式导出将不可用' })),
        ('kgm.mask           ：' + $(if ($status.kgmMask) { '已就绪' } else { '缺失，KGM/KGMA 转换可能失败' })),
        ('infra.dll          ：' + $(if ($status.infra) { '已就绪' } else { '缺失，部分工具链可能失败' })),
        ('ncmdump.exe        ：' + $(if ($status.ncmdump) { '已就绪' } else { '缺失，NCM 转换将不可用' })),
        ('KGMusicV3.db       ：' + $(if ($status.kugouDb) { '已找到' } else { '未找到，KGG 可能失败' })),
        '',
        ('数据库路径         ：' + $(if ($dbPath) { $dbPath } else { '未检测到' })),
        '',
        ('输出目录           ：' + $OutputDir),
        ('日志目录           ：' + $LogsDir)
    ) -join [Environment]::NewLine
}

Refresh-StatusView
Update-OutputControls
Update-FileActionState
Update-ResultSummary -StatusText '准备就绪' -Details @('请先添加文件，再选择输出格式开始转换。')

$btnPick.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Filter = '音频文件|*.kgg;*.kgm;*.kgma;*.ncm;*.mp3;*.wav;*.aac;*.m4a;*.flac;*.ogg;*.wma;*.opus'
    $dialog.Title = '选择音频文件'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($file in $dialog.FileNames) {
            if (-not $selectedFiles.Contains($file)) {
                $selectedFiles.Add($file)
                [void]$fileList.Items.Add($file)
            }
        }
        $fileCountLabel.Text = '共 ' + $selectedFiles.Count + ' 个文件'
        Update-FileActionState
        Update-ResultSummary -StatusText ('已添加 ' + $selectedFiles.Count + ' 个文件') -Details @('确认输出格式后即可开始转换。')
    }
})

$btnRemove.Add_Click({
    $itemsToRemove = @($fileList.SelectedItems)
    foreach ($item in $itemsToRemove) {
        [void]$selectedFiles.Remove([string]$item)
        [void]$fileList.Items.Remove($item)
    }
    $fileCountLabel.Text = '共 ' + $selectedFiles.Count + ' 个文件'
    Update-FileActionState
    if ($selectedFiles.Count -eq 0) {
        Update-ResultSummary -StatusText '准备就绪' -Details @('请先添加文件，再选择输出格式开始转换。')
    }
    else {
        Update-ResultSummary -StatusText ('当前保留 ' + $selectedFiles.Count + ' 个文件') -Details @('可继续添加文件或直接开始转换。')
    }
})

$fileList.Add_SelectedIndexChanged({
    Update-FileActionState
})

$btnClear.Add_Click({
    $selectedFiles.Clear()
    $fileList.Items.Clear()
    $logBox.Clear()
    $qualityCombo.SelectedIndex = 0
    $outputFormatCombo.SelectedIndex = 0
    $fileCountLabel.Text = '共 0 个文件'
    Update-OutputControls
    Update-FileActionState
    Update-ResultSummary -StatusText '准备就绪' -Details @('文件列表已清空，请重新添加文件。')
})

$outputFormatCombo.Add_SelectedIndexChanged({
    Update-OutputControls
    Update-ResultSummary -StatusText '输出设置已更新' -Details @('当前输出格式：' + $outputFormatCombo.SelectedItem.ToString())
})

$btnOutput.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList $OutputDir | Out-Null })
$btnLogs.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList $LogsDir | Out-Null })
$btnRefresh.Add_Click({ Refresh-StatusView; Update-ResultSummary -StatusText '环境状态已刷新' -Details @('如有工具缺失，请先补齐再转换。') })

$btnConvert.Add_Click({
    if ($selectedFiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先选择至少一个文件。', '未选择文件') | Out-Null
        return
    }

    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Set-BusyState -IsBusy $true
        Update-ResultSummary -StatusText '正在转换，请稍候' -Details @('输出格式：' + $outputFormatCombo.SelectedItem.ToString(), '待处理文件：' + $selectedFiles.Count + ' 个')
        $logBox.Text = '正在执行转换，请稍候...' + [Environment]::NewLine

        $result = Convert-AudioFiles -SourcePaths @($selectedFiles.ToArray()) -QualityPreset $qualityCombo.SelectedItem.ToString() -OutputFormat $outputFormatCombo.SelectedItem.ToString()
        $logBox.Text = ($result.messages -join [Environment]::NewLine)

        if ($result.outputCount -gt 0) {
            Update-ResultSummary -StatusText '转换完成' -Details @('输出格式：' + $result.outputFormat, '生成文件：' + $result.outputCount + ' 个', '可点击“打开输出目录”查看结果。')
            [System.Windows.Forms.MessageBox]::Show('转换完成，' + $result.outputFormat + ' 文件已输出到 output 文件夹。', '完成') | Out-Null
        }
        else {
            Update-ResultSummary -StatusText '转换完成，但未生成文件' -Details @('输出格式：' + $result.outputFormat, '请查看右侧日志定位原因。')
            [System.Windows.Forms.MessageBox]::Show('没有生成 ' + $result.outputFormat + ' 文件，请查看日志了解详情。', '转换完成但有警告') | Out-Null
        }
    }
    catch {
        $logBox.Text += '[错误] ' + $_.Exception.Message + [Environment]::NewLine
        Update-ResultSummary -StatusText '转换失败' -Details @('错误信息：' + $_.Exception.Message, '请查看右侧日志了解详情。')
        [System.Windows.Forms.MessageBox]::Show('转换失败：' + $_.Exception.Message, '错误') | Out-Null
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        Set-BusyState -IsBusy $false
    }
})

if (-not $env:KUGOU_HEADLESS) {
    [void]$form.ShowDialog()
}

