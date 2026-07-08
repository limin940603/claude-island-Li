# -*- coding: utf-8 -*-
# claude-island · daemon.ps1 —— WPF 桌面灵动岛 daemon(Windows PowerShell 5.1 / pwsh 皆可)
# 核心版:隐藏 STA 窗口 + 圆角 pill + 小熊状态头像 + 状态边框色 + 托盘 + FileSystemWatcher 吃事件 + 音效
# 用法:powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File daemon.ps1
# 调试:加 -Debug 参数会把事件处理写日志到 ~/.claude/hooks/claude-island/daemon.log
param(
  [switch]$DebugLog,
  [string]$RenderShot,   # 自检:把 pill/面板/控制台离屏渲染成 PNG 到该目录后退出(不截桌面,隐私安全)
  [switch]$ShowConsole   # 调试:启动即打开设置控制台
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# ---- 路径 ----
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Assets    = Join-Path $Root 'assets'
$RunDir    = Join-Path $env:USERPROFILE '.claude\hooks\claude-island'
$Events    = Join-Path $RunDir 'events.jsonl'
$PidFile   = Join-Path $RunDir '.daemon.pid'
$PosFile   = Join-Path $RunDir 'pos.json'
$LogFile   = Join-Path $RunDir 'daemon.log'
New-Item -ItemType Directory -Force $RunDir | Out-Null

function Log($m) { if ($DebugLog) { "$(Get-Date -Format 'HH:mm:ss.fff') $m" | Out-File -Append -Encoding UTF8 $LogFile } }

# ---- 单实例锁(RenderShot 自检实例不抢锁不写 pid) ----
if (-not $RenderShot) {
  if (Test-Path $PidFile) {
    $old = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) { Log "已有实例 $old,退出"; exit 0 }
  }
  $PID | Out-File -Encoding ASCII $PidFile
  Log "daemon 启动 pid=$PID"
}

# ---- 状态色板(语义化,与小熊表情一一对应) ----
$Colors = @{
  idle      = '#A89F95'   # 灰·就绪(半眯眼)
  done      = '#2FA84F'   # 绿·完成(开心弯眼)
  authorize = '#2B7FD4'   # 蓝·需授权(举爪请示)
  waiting   = '#E8A24A'   # 琥珀·等待输入(歪头?)
  error     = '#D64545'   # 红·命令报错(捂脸懊恼)
}
$SoundOf = @{ chime = 'chime.mp3'; notification = 'notification.mp3'; error = 'error.mp3'; pop = 'pop.mp3' }

# ---- 配置(静默/音量/按状态静音/不透明度/主题/暂停;控制台可视化改,也可手改 config.json) ----
$ConfigFile = Join-Path $RunDir 'config.json'
$script:Config = @{
  silent = $false; volume = 0.6; muteStates = @(); opacity = 0.94; theme = 'dark'; paused = $false
  # 每状态音效:'none'|捆绑文件名(assets\sfx)|绝对路径(如 C:\Windows\Media\*.wav)
  sounds = @{ done = 'chime.mp3'; authorize = 'notification.mp3'; error = 'error.mp3'; waiting = 'pop.mp3' }
  hwMonitor = $false   # 空闲30秒后 pill 轮换显示 CPU/内存,新事件立即让位
  edgeHide = $false    # 贴边隐藏:空闲30秒缩进屏幕顶边只留细条,悬停/新事件唤出
}
function Load-Config {
  if (Test-Path $ConfigFile) {
    try {
      $c = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($null -ne $c.silent)     { $script:Config.silent = [bool]$c.silent }
      if ($null -ne $c.volume)     { $script:Config.volume = [double]$c.volume }
      if ($null -ne $c.muteStates) { $script:Config.muteStates = @($c.muteStates) }
      if ($null -ne $c.opacity)    { $script:Config.opacity = [Math]::Min(1.0, [Math]::Max(0.35, [double]$c.opacity)) }
      if ($null -ne $c.theme -and "$($c.theme)" -in @('dark','light')) { $script:Config.theme = "$($c.theme)" }
      if ($null -ne $c.paused)     { $script:Config.paused = [bool]$c.paused }
      if ($null -ne $c.sounds) {
        foreach ($k in @('done','authorize','error','waiting')) {
          $v = $c.sounds.$k; if ($v) { $script:Config.sounds[$k] = "$v" }
        }
      }
      if ($null -ne $c.hwMonitor)  { $script:Config.hwMonitor = [bool]$c.hwMonitor }
      if ($null -ne $c.edgeHide)   { $script:Config.edgeHide = [bool]$c.edgeHide }
    } catch {}
  }
}
function Save-Config {
  try {
    $o = [pscustomobject]@{
      silent = $script:Config.silent; volume = $script:Config.volume; muteStates = @($script:Config.muteStates)
      opacity = $script:Config.opacity; theme = $script:Config.theme; paused = $script:Config.paused
      sounds = [pscustomobject]$script:Config.sounds; hwMonitor = $script:Config.hwMonitor; edgeHide = $script:Config.edgeHide
    }
    [System.IO.File]::WriteAllText($ConfigFile, ($o | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
  } catch {}
}
Load-Config

# ---- 每日事件计数归档(events.jsonl 只留40条环形,趋势靠这份;只留14天) ----
# 结构:{ lastTs: <已计数水位>, days: { 'yyyy-MM-dd': {done,error,authorize,waiting} } }
# lastTs 防重复:daemon 重启会重读整个环形缓冲,只有 ts > lastTs 的事件才计数
$StatsFile = Join-Path $RunDir 'stats.json'
function Update-Stats($events) {
  try {
    $days = @{}; $lastTs = [double]0
    if (Test-Path $StatsFile) {
      $j = Get-Content $StatsFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($null -ne $j.lastTs) { $lastTs = [double]$j.lastTs }
      if ($null -ne $j.days) {
        foreach ($p in $j.days.PSObject.Properties) {
          $days[$p.Name] = @{ done = [int]$p.Value.done; error = [int]$p.Value.error; authorize = [int]$p.Value.authorize; waiting = [int]$p.Value.waiting }
        }
      }
    }
    $touched = $false
    foreach ($e in $events) {
      if ([double]$e.ts -le $lastTs) { continue }
      $st = "$($e.state)"
      if ($st -notin @('done','error','authorize','waiting')) { continue }
      $day = ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$e.ts)).ToLocalTime().ToString('yyyy-MM-dd')
      if (-not $days.ContainsKey($day)) { $days[$day] = @{ done = 0; error = 0; authorize = 0; waiting = 0 } }
      $days[$day][$st]++; $touched = $true
    }
    $newMax = ($events | Measure-Object -Property ts -Maximum).Maximum
    if ($newMax -gt $lastTs) { $lastTs = [double]$newMax } elseif (-not $touched) { return }
    $keep = @($days.Keys | Sort-Object -Descending | Select-Object -First 14 | Sort-Object)
    $outDays = [ordered]@{}; foreach ($k in $keep) { $outDays[$k] = $days[$k] }
    $out = [pscustomobject]@{ lastTs = $lastTs; days = $outDays }
    [System.IO.File]::WriteAllText($StatsFile, ($out | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
  } catch { Log "stats 写入失败 $_" }
}
function Read-Stats {
  $r = @{}
  try {
    if (Test-Path $StatsFile) {
      $j = Get-Content $StatsFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($null -ne $j.days) {
        foreach ($p in $j.days.PSObject.Properties) {
          $r[$p.Name] = @{ done = [int]$p.Value.done; error = [int]$p.Value.error; authorize = [int]$p.Value.authorize; waiting = [int]$p.Value.waiting }
        }
      }
    }
  } catch {}
  return $r
}

# ---- 开机自启(与 install.ps1 同一快捷方式) ----
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeIsland.lnk'
$DaemonPath = $MyInvocation.MyCommand.Path
function Test-AutoStart { return (Test-Path $StartupLnk) }
function Set-AutoStart($on) {
  try {
    if ($on) {
      $ws = New-Object -ComObject WScript.Shell
      $sc = $ws.CreateShortcut($StartupLnk)
      $sc.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
      $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File `"$DaemonPath`""
      $sc.WorkingDirectory = Split-Path -Parent $DaemonPath
      $sc.Save()
    } else {
      Remove-Item $StartupLnk -Force -ErrorAction SilentlyContinue
    }
  } catch { Log "自启切换失败 $_" }
}

# ---- XAML(折叠态 pill:小熊 + 状态边框 + 标题) ----
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight"
        WindowStartupLocation="Manual" ResizeMode="NoResize">
  <StackPanel x:Name="Root" TextElement.FontFamily="Microsoft YaHei UI">
    <!-- 折叠态胶囊 -->
    <Border x:Name="Pill" CornerRadius="26" Background="#F0161310" Padding="8,6,18,6" Margin="24,24,24,24"
            BorderThickness="1" BorderBrush="#26FFFFFF" TextElement.FontFamily="Microsoft YaHei UI"
            HorizontalAlignment="Center">
      <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="2" Direction="270" Opacity="0.35" Color="#000000"/></Border.Effect>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Grid Width="58" Height="58">
          <Ellipse Width="48" Height="48" Fill="#FCFAF7"/>
          <Ellipse x:Name="BearEllipse" Width="48" Height="48" RenderTransformOrigin="0.5,0.5"
                   RenderOptions.BitmapScalingMode="HighQuality">
            <Ellipse.Fill>
              <ImageBrush x:Name="BearBrush" Stretch="UniformToFill"/>
            </Ellipse.Fill>
            <Ellipse.RenderTransform>
              <TransformGroup>
                <ScaleTransform x:Name="BearBreath" ScaleX="1" ScaleY="1"/>
                <ScaleTransform x:Name="BearPop" ScaleX="1" ScaleY="1"/>
              </TransformGroup>
            </Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse x:Name="Ring" Width="49.5" Height="49.5" Stroke="#A89F95" StrokeThickness="3">
            <Ellipse.Effect><DropShadowEffect x:Name="Glow" BlurRadius="24" ShadowDepth="0" Opacity="0.6" Color="#A89F95"/></Ellipse.Effect>
          </Ellipse>
        </Grid>
        <StackPanel Margin="13,0,0,0" VerticalAlignment="Center">
          <TextBlock x:Name="Title" Foreground="#F6F1EA" FontSize="15" FontWeight="SemiBold" Text="AI问老李"/>
          <TextBlock x:Name="Sub" Foreground="#B4A99D" FontSize="12.5" Text="就绪" Margin="0,2,0,0"/>
        </StackPanel>
        <Border x:Name="BadgeWrap" Width="22" Height="22" CornerRadius="11" Background="#A89F95"
                Margin="12,0,0,0" VerticalAlignment="Center" Visibility="Collapsed">
          <TextBlock x:Name="Badge" Foreground="White" FontSize="12" FontWeight="Bold"
                     HorizontalAlignment="Center" VerticalAlignment="Center" Text="0"/>
        </Border>
      </StackPanel>
    </Border>
    <!-- 展开态面板 -->
    <Border x:Name="Panel" Width="322" Margin="24,0,24,24" CornerRadius="20" Background="#F0161310"
            BorderThickness="1" BorderBrush="#26FFFFFF" HorizontalAlignment="Center" Visibility="Collapsed">
      <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="3" Direction="270" Opacity="0.38" Color="#000000"/></Border.Effect>
      <StackPanel>
        <Grid Margin="16,13,12,11">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="PanelTitle" Text="灵动岛" Foreground="#F6F1EA" FontSize="13.5" FontWeight="Bold"/>
            <Border x:Name="UnreadWrap" Background="#1AFFFFFF" CornerRadius="9" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="PanelUnread" Text="0 条未读" Foreground="#B4A99D" FontSize="11"/>
            </Border>
          </StackPanel>
          <TextBlock x:Name="ClearBtn" Text="清空" Foreground="#8A8178" FontSize="12"
                     HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand"/>
        </Grid>
        <Border x:Name="Sep1" Height="1" Background="#12FFFFFF"/>
        <StackPanel x:Name="MsgList" Margin="7,6"/>
        <Border x:Name="Sep2" Height="1" Background="#12FFFFFF"/>
        <Grid Margin="16,11">
          <TextBlock x:Name="ReadAllBtn" Text="全部已读" Foreground="#CFC6BB" FontSize="12.5"
                     HorizontalAlignment="Left" Cursor="Hand"/>
          <TextBlock x:Name="SettingsBtn" Text="⚙ 设置" Foreground="#8A8178" FontSize="12.5"
                     HorizontalAlignment="Right" Cursor="Hand"/>
        </Grid>
      </StackPanel>
    </Border>
  </StackPanel>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)
$RootPanel = $win.FindName('Root')   # 注意:$Root 已被脚本目录占用,勿混用
$Pill   = $win.FindName('Pill')
$BearBrush = $win.FindName('BearBrush')
$Title  = $win.FindName('Title')
$Sub    = $win.FindName('Sub')
$Glow   = $win.FindName('Glow')
$BadgeWrap = $win.FindName('BadgeWrap')
$Badge  = $win.FindName('Badge')
$BearBreath = $win.FindName('BearBreath')
$BearPop    = $win.FindName('BearPop')
$Ring   = $win.FindName('Ring')
$Panel      = $win.FindName('Panel')
$MsgList    = $win.FindName('MsgList')
$PanelUnread= $win.FindName('PanelUnread')
$ClearBtn   = $win.FindName('ClearBtn')
$ReadAllBtn = $win.FindName('ReadAllBtn')
$PanelTitle = $win.FindName('PanelTitle')
$UnreadWrap = $win.FindName('UnreadWrap')
$Sep1       = $win.FindName('Sep1')
$Sep2       = $win.FindName('Sep2')
$SettingsBtn = $win.FindName('SettingsBtn')

# ---- 主题+不透明度:实时作用于 pill/面板(状态色环/徽章/光晕语义两套主题一致) ----
$script:BC = New-Object System.Windows.Media.BrushConverter
function Apply-Style {
  $alpha = [byte][Math]::Round(255 * [double]$script:Config.opacity)
  $hexA = $alpha.ToString('X2')
  if ($script:Config.theme -eq 'light') {
    $bg = $script:BC.ConvertFromString("#${hexA}FCFAF7")
    $Pill.Background = $bg;                 $Panel.Background = $bg
    $Pill.BorderBrush = $script:BC.ConvertFromString('#24171717')
    $Panel.BorderBrush = $Pill.BorderBrush
    $Title.Foreground = $script:BC.ConvertFromString('#2A241E')
    $Sub.Foreground   = $script:BC.ConvertFromString('#8A8178')
    $PanelTitle.Foreground = $Title.Foreground
    $PanelUnread.Foreground = $Sub.Foreground
    $UnreadWrap.Background = $script:BC.ConvertFromString('#12171717')
    $ClearBtn.Foreground = $Sub.Foreground
    $ReadAllBtn.Foreground = $script:BC.ConvertFromString('#5C544A')
    $SettingsBtn.Foreground = $Sub.Foreground
    $Sep1.Background = $script:BC.ConvertFromString('#14171717'); $Sep2.Background = $Sep1.Background
    $script:RowTitleFg = '#2A241E'; $script:RowMetaFg = '#8A8178'
  } else {
    $bg = $script:BC.ConvertFromString("#${hexA}161310")
    $Pill.Background = $bg;                 $Panel.Background = $bg
    $Pill.BorderBrush = $script:BC.ConvertFromString('#26FFFFFF')
    $Panel.BorderBrush = $Pill.BorderBrush
    $Title.Foreground = $script:BC.ConvertFromString('#F6F1EA')
    $Sub.Foreground   = $script:BC.ConvertFromString('#B4A99D')
    $PanelTitle.Foreground = $Title.Foreground
    $PanelUnread.Foreground = $Sub.Foreground
    $UnreadWrap.Background = $script:BC.ConvertFromString('#1AFFFFFF')
    $ClearBtn.Foreground = $script:BC.ConvertFromString('#8A8178')
    $ReadAllBtn.Foreground = $script:BC.ConvertFromString('#CFC6BB')
    $SettingsBtn.Foreground = $script:BC.ConvertFromString('#8A8178')
    $Sep1.Background = $script:BC.ConvertFromString('#12FFFFFF'); $Sep2.Background = $Sep1.Background
    $script:RowTitleFg = '#F6F1EA'; $script:RowMetaFg = '#B4A99D'
  }
}

# ---- 离屏渲染自检:把控件渲染成 PNG(不截桌面,隐私安全) ----
function Save-Shot($element, $path) {
  try {
    $element.UpdateLayout()
    $w = [int][Math]::Ceiling($element.ActualWidth); $h = [int][Math]::Ceiling($element.ActualHeight)
    if ($w -le 0 -or $h -le 0) { Log "Save-Shot 尺寸为0: $path"; return }
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($element)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::OpenWrite($path); $enc.Save($fs); $fs.Close()
  } catch { Log "Save-Shot 失败 $_" }
}

# ---- 位置:顶部居中(或读 pos.json) ----
$win.Add_SourceInitialized({
  $wa = [System.Windows.SystemParameters]::WorkArea
  if (Test-Path $PosFile) {
    try { $p = Get-Content $PosFile -Raw | ConvertFrom-Json; $win.Left = [double]$p.x; $win.Top = [double]$p.y }
    catch { $win.Left = ($wa.Width - $win.ActualWidth)/2; $win.Top = 12 }
  } else { $win.Left = ($wa.Width - 320)/2; $win.Top = 12 }
})

# ---- 点 pill:拖动(移动了) or 展开/收起面板(纯点击);位置持久化 ----
$script:dragged = $false
$Pill.Add_MouseLeftButtonDown({
  $script:dragged = $false
  try { $win.DragMove() } catch {}
  if (-not $script:dragged) { Toggle-Panel }   # 没拖动 = 点击 → 切面板
})
$win.Add_LocationChanged({
  if ($script:EdgeAnimating -or $script:EdgeHidden) { return }   # 贴边滑动中不当拖动、不持久化隐藏坐标
  $script:dragged = $true
  try { @{ x = $win.Left; y = $win.Top } | ConvertTo-Json | Out-File -Encoding UTF8 $PosFile } catch {}
})

# ---- 未读徽章 ----
$script:Unread = 0
function Set-Badge($n) {
  $script:Unread = $n
  if ($n -le 0) { $BadgeWrap.Visibility = 'Collapsed' }
  else { $BadgeWrap.Visibility = 'Visible'; if ($n -ge 9) { $Badge.Text = '9+' } else { $Badge.Text = "$n" } }
}
# 面板按钮:清空 / 全部已读
$ClearBtn.Add_MouseLeftButtonUp({
  try { Remove-Item $Events -Force -ErrorAction SilentlyContinue } catch {}
  $MsgList.Children.Clear(); Set-Badge 0; $PanelUnread.Text = '0 条未读'
})
$ReadAllBtn.Add_MouseLeftButtonUp({ Set-Badge 0; $PanelUnread.Text = '0 条未读' })
$SettingsBtn.Add_MouseLeftButtonUp({ Show-Console })   # 面板齿轮直达控制台

# ---- 播音效 ----
$script:Player = New-Object System.Windows.Media.MediaPlayer
function Resolve-SoundFile($v) {
  if (-not $v -or "$v" -eq 'none') { return $null }
  if ([System.IO.Path]::IsPathRooted("$v")) { return "$v" }
  return (Join-Path (Join-Path $Assets 'sfx') "$v")
}
function Play-File($f) {
  if ($f -and (Test-Path $f)) { try { $script:Player.Open([Uri]$f); $script:Player.Volume = [double]$script:Config.volume; $script:Player.Play() } catch { Log "音效失败 $_" } }
}
function Play-Sound($key) {
  if (-not $key -or -not $SoundOf.ContainsKey($key)) { return }
  Play-File (Join-Path (Join-Path $Assets 'sfx') $SoundOf[$key])
}
# 按状态取配置音效('none'=不响);无配置回落事件自带 sound 键
function Play-StateSound($state, $fallbackKey) {
  if ($script:Config.sounds.ContainsKey($state)) { Play-File (Resolve-SoundFile $script:Config.sounds[$state]) }
  elseif ($fallbackKey) { Play-Sound $fallbackKey }
}

# ---- 音效菜单(控制台下拉用:自带4个 + 系统 C:\Windows\Media 精选,存在才入列) ----
$script:SoundMenu = New-Object System.Collections.ArrayList
[void]$script:SoundMenu.Add(@{ label = '无(不响)'; value = 'none' })
[void]$script:SoundMenu.Add(@{ label = '自带·清脆铃 chime'; value = 'chime.mp3' })
[void]$script:SoundMenu.Add(@{ label = '自带·提醒 notification'; value = 'notification.mp3' })
[void]$script:SoundMenu.Add(@{ label = '自带·警示 error'; value = 'error.mp3' })
[void]$script:SoundMenu.Add(@{ label = '自带·啵 pop'; value = 'pop.mp3' })
foreach ($s in @(
  @{ label = '系统·叮当 chimes';  file = 'chimes.wav' },
  @{ label = '系统·叮 ding';      file = 'ding.wav' },
  @{ label = '系统·和弦 chord';   file = 'chord.wav' },
  @{ label = '系统·嗒哒 tada';    file = 'tada.wav' },
  @{ label = '系统·通用通知';      file = 'Windows Notify System Generic.wav' },
  @{ label = '系统·消息';          file = 'Windows Notify Messaging.wav' },
  @{ label = '系统·日历';          file = 'Windows Notify Calendar.wav' },
  @{ label = '系统·警告';          file = 'Windows Exclamation.wav' },
  @{ label = '系统·严重错误';      file = 'Windows Critical Stop.wav' },
  @{ label = '系统·登录';          file = 'Windows Logon.wav' }
)) {
  $p = Join-Path "$env:SystemRoot\Media" $s.file
  if (Test-Path $p) { [void]$script:SoundMenu.Add(@{ label = $s.label; value = $p }) }
}

# ---- 头像加载(assets\bear-{state}.png,缺则不换) ----
function Set-Bear($state) {
  $img = Join-Path $Assets "bear-$state.png"
  if (Test-Path $img) {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.UriSource = [Uri]$img; $bmp.EndInit()
    $BearBrush.ImageSource = $bmp
  }
}

# ---- 弹跳:每次新事件小熊"啵"地弹一下(BackEase 回弹) ----
function Pop-Bear {
  $dur = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(320))
  $ease = New-Object System.Windows.Media.Animation.BackEase; $ease.Amplitude = 0.7; $ease.EasingMode = 'EaseOut'
  $da = New-Object System.Windows.Media.Animation.DoubleAnimation
  $da.From = 0.78; $da.To = 1.0; $da.Duration = $dur; $da.EasingFunction = $ease
  $BearPop.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $da)
  $BearPop.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $da)
}

# ---- 呼吸:常态微动,让小熊"活着"(缓慢缩放 + 光晕明暗脉动,永久循环) ----
function Start-Breathing {
  $dur = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(1.6))
  $ez  = New-Object System.Windows.Media.Animation.SineEase; $ez.EasingMode = 'EaseInOut'
  $forever = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $breath = New-Object System.Windows.Media.Animation.DoubleAnimation
  $breath.From = 0.9; $breath.To = 1.0; $breath.Duration = $dur
  $breath.AutoReverse = $true; $breath.RepeatBehavior = $forever; $breath.EasingFunction = $ez
  $BearBreath.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $breath)
  $BearBreath.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $breath)
  $glowPulse = New-Object System.Windows.Media.Animation.DoubleAnimation
  $glowPulse.From = 0.5; $glowPulse.To = 1.0; $glowPulse.Duration = $dur
  $glowPulse.AutoReverse = $true; $glowPulse.RepeatBehavior = $forever; $glowPulse.EasingFunction = $ez
  $Glow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $glowPulse)
  Log "呼吸动画已启动"
}

# ---- 展开面板:读事件 + 渲染行 + 切换 ----
function BearUri($state) {
  $p = (Join-Path $Assets "bear-$state.png") -replace '\\','/'
  return "file:///$p"
}
function RelTime($ts) {
  if (-not $ts) { return '' }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $s = [int]([math]::Max(0, $now - [double]$ts) / 1000)
  if ($s -lt 60) { return '刚刚' }
  $m = [int]($s / 60); if ($m -lt 60) { return "$m 分钟前" }
  $h = [int]($m / 60); if ($h -lt 24) { return "$h 小时前" }
  return "$([int]($h / 24)) 天前"
}
function XmlEsc($s) { return ("$s" -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') }
function Read-AllEvents {
  if (-not (Test-Path $Events)) { return @() }
  $raw = $null
  try { $raw = [System.IO.File]::ReadAllText($Events, [System.Text.Encoding]::UTF8) } catch { return @() }
  $list = @()
  foreach ($line in ($raw -split "`n")) {
    $t = $line.Trim(); if (-not $t) { continue }
    try { $list += ($t | ConvertFrom-Json) } catch {}
  }
  return $list
}
function Build-Row($e) {
  $st = "$($e.state)"; if (-not $st) { $st = 'idle' }
  $col = $Colors[$st]; if (-not $col) { $col = $Colors['idle'] }
  $uri = BearUri $st
  $title = XmlEsc $e.title
  $meta = XmlEsc ((@($e.project, (RelTime $e.ts)) | Where-Object { $_ }) -join '  ·  ')
  $rowXaml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Padding="10,9" CornerRadius="13">
  <StackPanel Orientation="Horizontal">
    <Border Width="3" CornerRadius="2" Background="$col" Margin="0,0,11,0"/>
    <Grid Width="34" Height="34" Margin="0,0,11,0">
      <Ellipse Width="34" Height="34" Fill="#FCFAF7"/>
      <Ellipse Width="34" Height="34" RenderOptions.BitmapScalingMode="HighQuality">
        <Ellipse.Fill><ImageBrush ImageSource="$uri" Stretch="UniformToFill"/></Ellipse.Fill>
      </Ellipse>
      <Ellipse Width="34" Height="34" Stroke="$col" StrokeThickness="1.6"/>
    </Grid>
    <StackPanel VerticalAlignment="Center">
      <TextBlock Text="$title" Foreground="$($script:RowTitleFg)" FontSize="13.5" FontWeight="SemiBold"/>
      <TextBlock Text="$meta" Foreground="$($script:RowMetaFg)" FontSize="11.5" Margin="0,2,0,0"/>
    </StackPanel>
  </StackPanel>
</Border>
"@
  return [Windows.Markup.XamlReader]::Parse($rowXaml)
}
function Populate-Panel {
  $all = @(Read-AllEvents)
  if ($all.Count -gt 6) { $take = $all[($all.Count - 6)..($all.Count - 1)] } else { $take = $all }
  $take = @($take); [array]::Reverse($take)   # 最新在上
  $MsgList.Children.Clear()
  foreach ($ev in $take) { try { [void]$MsgList.Children.Add((Build-Row $ev)) } catch { Log "行渲染失败 $_" } }
  if ($take.Count -eq 0) {
    $empty = New-Object System.Windows.Controls.TextBlock
    $empty.Text = '暂无消息'; $empty.Foreground = 'Gray'; $empty.FontSize = 12; $empty.Margin = '10,14'
    [void]$MsgList.Children.Add($empty)
  }
  $PanelUnread.Text = "$($script:Unread) 条未读"
}
$script:CollapseTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:CollapseTimer.Interval = [TimeSpan]::FromSeconds(8)
$script:CollapseTimer.Add_Tick({ $script:CollapseTimer.Stop(); $Panel.Visibility = 'Collapsed' })
function Toggle-Panel {
  if ($Panel.Visibility -eq [System.Windows.Visibility]::Visible) {
    $Panel.Visibility = 'Collapsed'; $script:CollapseTimer.Stop()
  } else {
    Populate-Panel; $Panel.Visibility = 'Visible'; Set-Badge 0
    $script:CollapseTimer.Stop(); $script:CollapseTimer.Start()
  }
}

# ---- 应用状态(切头像+边框色+标题+徽章+弹跳+音效) ----
function Apply-Event($e) {
  $state = "$($e.state)"; if (-not $state) { $state = 'idle' }
  $col = $Colors[$state]; if (-not $col) { $col = $Colors['idle'] }
  $brush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($col)
  $Ring.Stroke = $brush                 # 状态色移到头像描边环
  $BadgeWrap.Background = $brush         # 徽章同状态色
  $Glow.Color = $brush.Color            # 只换色,亮度由呼吸动画掌管
  if ($e.title) { $Title.Text = "$($e.title)" } else { $Title.Text = 'AI问老李' }
  $subParts = @($e.project, $e.sub) | Where-Object { $_ } | ForEach-Object { "$_" }
  $Sub.Text = ($subParts -join ' · ')
  Set-Bear $state
  Pop-Bear                              # 换头像后弹一下
  if (-not $script:Config.silent) { Play-StateSound $state "$($e.sound)" }
  $script:LastEventAt = [DateTime]::Now  # 通知优先:硬件监控让位30秒
  $script:HwShowing = $false
  Wake-Island                            # 触发即弹出:贴边隐藏中来事件立即滑出
  Log "应用事件 state=$state title=$($e.title) project=$($e.project)"
}

# ---- 轮询处理:容错读 + 处理所有新事件(徽章计全部,视觉/音效取最新) ----
$script:LastTs = 0
function Handle-EventsFile {
  if (-not (Test-Path $Events)) { return }
  $raw = $null
  try { $raw = [System.IO.File]::ReadAllText($Events, [System.Text.Encoding]::UTF8) }
  catch { return }  # 被 emit 写入瞬间读失败,静默跳过,下个 tick 再来
  if ([string]::IsNullOrWhiteSpace($raw)) { return }
  $new = @()
  foreach ($line in ($raw -split "`n")) {
    $t = $line.Trim(); if (-not $t) { continue }
    try { $o = $t | ConvertFrom-Json } catch { continue }
    if ($o.ts -gt $script:LastTs) { $new += $o }
  }
  if ($new.Count -eq 0) { return }
  $script:LastTs = ($new | Measure-Object -Property ts -Maximum).Maximum
  Load-Config                                # 有新事件才读配置(静默/静音状态)
  Update-Stats $new                          # 统计计事实事件量(静音/暂停也照记)
  if ($script:Config.paused) { return }      # 已暂停:daemon 保活只记录,不弹不响不计数
  $visible = @($new | Where-Object { $script:Config.muteStates -notcontains "$($_.state)" })
  if ($visible.Count -eq 0) { return }       # 该状态被静音则整条忽略(不弹不响不计数)
  Set-Badge ($script:Unread + $visible.Count)
  Apply-Event ($visible[-1])
}

# ---- DispatcherTimer 轮询 events.jsonl(UI 线程,规避 FileSystemWatcher+runspace 坑) ----
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({ Handle-EventsFile })
$timer.Start()

# ---- 硬件监控:空闲30秒后 pill 显示 CPU/内存(3秒采样;新事件立即让位) ----
# 用 CIM 性能类而非 PerformanceCounter:计数器名在中文 Windows 被本地化,CIM 类名语言无关
$script:LastEventAt = [DateTime]::MinValue
$script:HwShowing = $false
function Get-HwSample {
  try {
    $cpu = [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    $os = Get-CimInstance Win32_OperatingSystem
    $mem = [int](100 - 100 * $os.FreePhysicalMemory / $os.TotalVisibleMemorySize)
    return "CPU $cpu%  ·  内存 $mem%"
  } catch { Log "硬件采样失败 $_"; return $null }
}
function Show-HwState($sample) {
  if (-not $script:HwShowing) {
    $script:HwShowing = $true
    $brush = $script:BC.ConvertFromString($Colors['idle'])
    $Ring.Stroke = $brush; $Glow.Color = $brush.Color
    Set-Bear 'idle'
    $Title.Text = '系统监控'
  }
  $Sub.Text = $sample
}
$hwTimer = New-Object System.Windows.Threading.DispatcherTimer
$hwTimer.Interval = [TimeSpan]::FromSeconds(3)
$hwTimer.Add_Tick({
  if (-not $script:Config.hwMonitor) { return }
  if (([DateTime]::Now - $script:LastEventAt).TotalSeconds -lt 30) { return }   # 通知刚来,让位
  $s = Get-HwSample
  if ($s) { Show-HwState $s }
})
if (-not $RenderShot) { $hwTimer.Start() }

# ---- 贴边隐藏:空闲30秒缩进屏幕顶边只留细条;悬停/新事件唤出(触发即弹出) ----
$script:EdgeHidden = $false
$script:EdgeAnimating = $false
$script:ShownTop = $null
$script:LastWakeAt = [DateTime]::Now
$script:SlideTarget = 0.0
$script:SlideTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SlideTimer.Interval = [TimeSpan]::FromMilliseconds(15)
$script:SlideTimer.Add_Tick({
  $cur = $win.Top; $diff = $script:SlideTarget - $cur
  if ([Math]::Abs($diff) -lt 1.5) { $win.Top = $script:SlideTarget; $script:SlideTimer.Stop(); $script:EdgeAnimating = $false }
  else { $win.Top = $cur + $diff * 0.28 }   # 指数缓动,约0.3秒滑完
})
function Slide-To($t) { $script:SlideTarget = [double]$t; $script:EdgeAnimating = $true; $script:SlideTimer.Start() }
function Hide-Island {
  if ($script:EdgeHidden) { return }
  $script:ShownTop = $win.Top
  $script:EdgeHidden = $true
  Slide-To (30.0 - $win.ActualHeight)   # 窗口底部24px是透明留白,留30即露出约6px pill细条
  Log "贴边缩回"
}
function Wake-Island {
  $script:LastWakeAt = [DateTime]::Now
  if (-not $script:EdgeHidden) { return }
  $script:EdgeHidden = $false
  $t = 12.0; if ($null -ne $script:ShownTop) { $t = [double]$script:ShownTop }
  Slide-To $t
  Log "贴边唤出"
}
# 悬停意图判定:细条上停留0.4秒才唤出——防止鼠标扫过浏览器标签栏/屏幕顶边误触
$script:HoverTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:HoverTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:HoverTimer.Add_Tick({
  $script:HoverTimer.Stop()
  if ($script:EdgeHidden -and $win.IsMouseOver) { Wake-Island }
})
$win.Add_MouseEnter({
  if ($script:EdgeHidden) { $script:HoverTimer.Stop(); $script:HoverTimer.Start() }
  elseif ($script:Config.edgeHide) { $script:LastWakeAt = [DateTime]::Now }
})
$win.Add_MouseLeave({ $script:HoverTimer.Stop() })
$script:EdgeTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EdgeTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:EdgeTimer.Add_Tick({
  if (-not $script:Config.edgeHide) { if ($script:EdgeHidden) { Wake-Island }; return }   # 开关关掉时自动弹回
  if ($script:EdgeHidden -or $script:EdgeAnimating) { return }
  if ($win.IsMouseOver) { $script:LastWakeAt = [DateTime]::Now; return }
  if ($Panel.Visibility -eq [System.Windows.Visibility]::Visible) { $script:LastWakeAt = [DateTime]::Now; return }
  if ($win.Top -gt 60) { return }   # 岛不贴顶边(被拖到屏中间用)不吸附
  if (([DateTime]::Now - $script:LastWakeAt).TotalSeconds -ge 30) { Hide-Island }
})
if (-not $RenderShot) { $script:EdgeTimer.Start() }

# ---- 设置控制台(按已批准概念稿 v0.2 移植;真岛就在屏上,改动即所见) ----
$script:CWin = $null
$script:CW = @{}
$script:CWSyncing = $false

function Sync-Switch($sw, $on) {
  $knob = $sw.Child
  if ($on) { $sw.Background = $script:BC.ConvertFromString('#E26934'); $knob.HorizontalAlignment = 'Right'; $knob.Margin = '0,0,3,0' }
  else     { $sw.Background = $script:BC.ConvertFromString('#E4DCCF'); $knob.HorizontalAlignment = 'Left';  $knob.Margin = '3,0,0,0' }
}
function Toggle-Mute($state, $sw) {
  $m = @($script:Config.muteStates)
  if ($m -contains $state) { $m = @($m | Where-Object { $_ -ne $state }) } else { $m += $state }
  $script:Config.muteStates = $m; Save-Config
  Sync-Switch $sw ($m -contains $state)
}
function Sync-Seg {
  $dark = ($script:Config.theme -eq 'dark')
  $script:CW.SegDark.Background  = if ($dark) { $script:BC.ConvertFromString('#FFFFFF') } else { $script:BC.ConvertFromString('#00FFFFFF') }
  $script:CW.SegDarkTx.Foreground  = if ($dark) { $script:BC.ConvertFromString('#2A241E') } else { $script:BC.ConvertFromString('#8A8178') }
  $script:CW.SegLight.Background = if ($dark) { $script:BC.ConvertFromString('#00FFFFFF') } else { $script:BC.ConvertFromString('#FFFFFF') }
  $script:CW.SegLightTx.Foreground = if ($dark) { $script:BC.ConvertFromString('#8A8178') } else { $script:BC.ConvertFromString('#2A241E') }
}
function Sync-Master {
  if ($script:Config.paused) {
    $script:CW.CMasterLabel.Text = '已暂停'; $script:CW.CMasterLabel.Foreground = $script:BC.ConvertFromString('#8A8178')
  } else {
    $script:CW.CMasterLabel.Text = '已开启'; $script:CW.CMasterLabel.Foreground = $script:BC.ConvertFromString('#2FA84F')
  }
  Sync-Switch $script:CW.SwMaster (-not $script:Config.paused)
}
function Paint-Trend {
  $cv = $script:CW.TrendCanvas; if (-not $cv) { return }
  $cv.Children.Clear()
  $stats = Read-Stats
  $days = @(); for ($i = 6; $i -ge 0; $i--) { $days += (Get-Date).AddDays(-$i).ToString('yyyy-MM-dd') }
  $totals = @()
  foreach ($d in $days) {
    if ($stats.ContainsKey($d)) { $s = $stats[$d]; $totals += [int]($s.done + $s.error + $s.authorize + $s.waiting) }
    else { $totals += 0 }
  }
  $max = ($totals | Measure-Object -Maximum).Maximum; if ($max -lt 1) { $max = 1 }
  $H = 52.0; $x0 = 10.0; $x1 = 276.0
  $pts = New-Object System.Windows.Media.PointCollection
  for ($i = 0; $i -lt 7; $i++) {
    $x = $x0 + ($x1 - $x0) * $i / 6.0
    $y = 6.0 + ($H - 12.0) * (1.0 - $totals[$i] / $max)
    $pts.Add((New-Object System.Windows.Point($x, $y)))
  }
  $ppts = New-Object System.Windows.Media.PointCollection
  foreach ($p in $pts) { $ppts.Add($p) }
  $ppts.Add((New-Object System.Windows.Point($x1, $H))); $ppts.Add((New-Object System.Windows.Point($x0, $H)))
  $poly = New-Object System.Windows.Shapes.Polygon
  $poly.Points = $ppts; $poly.Fill = $script:BC.ConvertFromString('#2EE26934')
  [void]$cv.Children.Add($poly)
  $line = New-Object System.Windows.Shapes.Polyline
  $line.Points = $pts; $line.Stroke = $script:BC.ConvertFromString('#E26934'); $line.StrokeThickness = 2; $line.StrokeLineJoin = 'Round'
  [void]$cv.Children.Add($line)
  for ($i = 0; $i -lt 7; $i++) {
    $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 5; $dot.Height = 5; $dot.Fill = $line.Stroke
    [System.Windows.Controls.Canvas]::SetLeft($dot, $pts[$i].X - 2.5); [System.Windows.Controls.Canvas]::SetTop($dot, $pts[$i].Y - 2.5)
    [void]$cv.Children.Add($dot)
    $tb = New-Object System.Windows.Controls.TextBlock
    if ($i -eq 6) { $tb.Text = '今天' } else { $tb.Text = ([DateTime]::ParseExact($days[$i], 'yyyy-MM-dd', $null)).ToString('M/d') }
    $tb.FontSize = 9; $tb.Foreground = $script:BC.ConvertFromString('#A89F95')
    [System.Windows.Controls.Canvas]::SetLeft($tb, $pts[$i].X - 10); [System.Windows.Controls.Canvas]::SetTop($tb, $H + 6.0)
    [void]$cv.Children.Add($tb)
  }
}
function Fill-SoundCombo($combo, $current) {
  $combo.Items.Clear(); $sel = $null
  foreach ($s in $script:SoundMenu) {
    $it = New-Object System.Windows.Controls.ComboBoxItem
    $it.Content = $s.label; $it.Tag = $s.value
    [void]$combo.Items.Add($it)
    if ("$($s.value)" -eq "$current") { $sel = $it }
  }
  if ($sel) { $combo.SelectedItem = $sel }
  elseif ($combo.Items.Count -gt 1) { $combo.SelectedIndex = 1 }   # 未匹配回落自带第一个
}
function Sync-ConsoleUI {
  if (-not $script:CWin) { return }
  $script:CWSyncing = $true
  try {
    Sync-Master
    Sync-Switch $script:CW.SwAuto (Test-AutoStart)
    Sync-Switch $script:CW.SwSilent ([bool]$script:Config.silent)
    Sync-Switch $script:CW.SwHw ([bool]$script:Config.hwMonitor)
    Sync-Switch $script:CW.SwEdge ([bool]$script:Config.edgeHide)
    $script:CW.VolSlider.Value = [Math]::Round(100 * [double]$script:Config.volume)
    $script:CW.VolVal.Text = "$([int]$script:CW.VolSlider.Value)%"
    $script:CW.AlphaSlider.Value = [Math]::Round(100 * [double]$script:Config.opacity)
    $script:CW.AlphaVal.Text = "$([int]$script:CW.AlphaSlider.Value)%"
    Sync-Seg
    $m = @($script:Config.muteStates)
    Sync-Switch $script:CW.SwMuteDone ($m -contains 'done')
    Sync-Switch $script:CW.SwMuteAuth ($m -contains 'authorize')
    Sync-Switch $script:CW.SwMuteErr  ($m -contains 'error')
    Sync-Switch $script:CW.SwMuteWait ($m -contains 'waiting')
    Sync-Switch $script:CW.SwMuteIdle ($m -contains 'idle')
    Fill-SoundCombo $script:CW.SndDone $script:Config.sounds['done']
    Fill-SoundCombo $script:CW.SndAuth $script:Config.sounds['authorize']
    Fill-SoundCombo $script:CW.SndErr  $script:Config.sounds['error']
    Fill-SoundCombo $script:CW.SndWait $script:Config.sounds['waiting']
    $today = (Get-Date).ToString('yyyy-MM-dd'); $stats = Read-Stats
    if ($stats.ContainsKey($today)) { $t = $stats[$today] } else { $t = @{ done = 0; error = 0; authorize = 0; waiting = 0 } }
    $script:CW.SnDone.Text = "$($t.done)"; $script:CW.SnErr.Text = "$($t.error)"
    $script:CW.SnAuth.Text = "$($t.authorize)"; $script:CW.SnWait.Text = "$($t.waiting)"
    Paint-Trend
  } finally { $script:CWSyncing = $false }
}
function Show-Console {
  if ($script:CWin) { try { $script:CWin.Activate(); Sync-ConsoleUI; return } catch { $script:CWin = $null } }
  $bDone = BearUri 'done'; $bAuth = BearUri 'authorize'; $bErr = BearUri 'error'; $bWait = BearUri 'waiting'; $bIdle = BearUri 'idle'
  [xml]$cxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude 灵动岛 · 控制台" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        SizeToContent="Height" Width="748" WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        ShowInTaskbar="True" TextElement.FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <!-- 暖橙圆点滑块(对齐概念稿):左段橙轨+右段米轨+白底橙边圆拇指 -->
    <Style x:Key="WarmSlider" TargetType="Slider">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Height" Value="18"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid>
              <Track x:Name="PART_Track" VerticalAlignment="Center">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" IsTabStop="False" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="4" CornerRadius="2" Background="#E26934"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" IsTabStop="False" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="4" CornerRadius="2" Background="#EFE9DE"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="16" Height="16" Focusable="False">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Fill="#FFFFFF" Stroke="#E26934" StrokeThickness="2">
                          <Ellipse.Effect><DropShadowEffect BlurRadius="4" ShadowDepth="1" Opacity="0.2" Color="#000000"/></Ellipse.Effect>
                        </Ellipse>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Margin="14" CornerRadius="14" Background="#F9F6F1">
    <Border.Effect><DropShadowEffect BlurRadius="22" ShadowDepth="4" Direction="270" Opacity="0.30" Color="#000000"/></Border.Effect>
    <StackPanel>
      <Border x:Name="CTitleBar" Background="#FDFBF8" CornerRadius="14,14,0,0" Height="40" Padding="14,0,6,0">
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="22" Height="22"><Ellipse.Fill><ImageBrush ImageSource="$bIdle" Stretch="UniformToFill"/></Ellipse.Fill></Ellipse>
            <TextBlock Text="Claude 灵动岛 · 控制台" FontSize="12.5" FontWeight="SemiBold" Foreground="#6F665D" Margin="9,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <Border x:Name="CMin" Width="36" Height="28" CornerRadius="7" Background="#00000000" Cursor="Hand">
              <TextBlock Text="─" FontSize="12" Foreground="#9B9187" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <Border x:Name="CClose" Width="36" Height="28" CornerRadius="7" Background="#00000000" Cursor="Hand">
              <TextBlock Text="✕" FontSize="12" Foreground="#9B9187" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </StackPanel>
        </Grid>
      </Border>
      <StackPanel Margin="20,16,20,0">
        <Border Background="#FFFFFF" BorderThickness="1" BorderBrush="#ECE6DB" CornerRadius="16" Padding="16,14">
          <Grid>
            <StackPanel Orientation="Horizontal">
              <Grid Width="52" Height="52">
                <Ellipse Fill="#FCFAF7"/>
                <Ellipse RenderOptions.BitmapScalingMode="HighQuality">
                  <Ellipse.Fill><ImageBrush ImageSource="$bDone" Stretch="UniformToFill"/></Ellipse.Fill>
                </Ellipse>
                <Ellipse Stroke="#E26934" StrokeThickness="2.5"/>
              </Grid>
              <StackPanel Margin="13,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="Claude 灵动岛" FontSize="16" FontWeight="Bold" Foreground="#2A241E"/>
                <TextBlock Text="桌面通知器 · Windows 版 · daemon 运行中" FontSize="11.5" Foreground="#8A8178" Margin="0,3,0,0"/>
              </StackPanel>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <TextBlock x:Name="CMasterLabel" Text="已开启" FontSize="13" FontWeight="SemiBold" Foreground="#2FA84F" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <Border x:Name="SwMaster" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" VerticalAlignment="Center">
                <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
            </StackPanel>
          </Grid>
        </Border>
        <Grid Margin="0,16,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="1.08*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="0.92*"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
          <Border Background="#FFFFFF" BorderThickness="1" BorderBrush="#ECE6DB" CornerRadius="16" Padding="17,14" VerticalAlignment="Top">
            <StackPanel>
              <TextBlock Text="常规设置" FontSize="13" FontWeight="Bold" Foreground="#2A241E"/>
              <TextBlock Text="改动即时生效并写入 config.json" FontSize="11" Foreground="#8A8178" Margin="0,3,0,6"/>
              <Grid Margin="0,10,0,10">
                <StackPanel Margin="0,0,56,0">
                  <TextBlock Text="开机自启动" FontSize="13" FontWeight="SemiBold" Foreground="#2A241E"/>
                  <TextBlock Text="跟随 Windows 登录启动灵动岛" FontSize="11" Foreground="#8A8178" Margin="0,2,0,0"/>
                </StackPanel>
                <Border x:Name="SwAuto" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                </Border>
              </Grid>
              <Border Height="1" Background="#F0EAE0"/>
              <Grid Margin="0,10,0,10">
                <StackPanel Margin="0,0,56,0">
                  <TextBlock Text="静默模式" FontSize="13" FontWeight="SemiBold" Foreground="#2A241E"/>
                  <TextBlock Text="只弹岛不响铃" FontSize="11" Foreground="#8A8178" Margin="0,2,0,0"/>
                </StackPanel>
                <Border x:Name="SwSilent" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                </Border>
              </Grid>
              <Border Height="1" Background="#F0EAE0"/>
              <StackPanel Margin="0,10,0,10">
                <TextBlock Text="提示音量" FontSize="13" FontWeight="SemiBold" Foreground="#2A241E"/>
                <Grid Margin="0,7,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions>
                  <Slider x:Name="VolSlider" Style="{StaticResource WarmSlider}" Minimum="0" Maximum="100" Value="60" VerticalAlignment="Center" IsMoveToPointEnabled="True"/>
                  <TextBlock x:Name="VolVal" Grid.Column="1" Text="60%" FontSize="12" FontWeight="Bold" Foreground="#E26934" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
              </StackPanel>
              <Border Height="1" Background="#F0EAE0"/>
              <StackPanel Margin="0,10,0,10">
                <TextBlock Text="岛体不透明度" FontSize="13" FontWeight="SemiBold" Foreground="#2A241E"/>
                <Grid Margin="0,7,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions>
                  <Slider x:Name="AlphaSlider" Style="{StaticResource WarmSlider}" Minimum="35" Maximum="100" Value="94" VerticalAlignment="Center" IsMoveToPointEnabled="True"/>
                  <TextBlock x:Name="AlphaVal" Grid.Column="1" Text="94%" FontSize="12" FontWeight="Bold" Foreground="#E26934" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
              </StackPanel>
              <Border Height="1" Background="#F0EAE0"/>
              <Grid Margin="0,10,0,4">
                <StackPanel Margin="0,0,120,0">
                  <TextBlock Text="岛体主题" FontSize="13" FontWeight="SemiBold" Foreground="#2A241E"/>
                  <TextBlock Text="改动直接作用于屏上真岛" FontSize="11" Foreground="#8A8178" Margin="0,2,0,0"/>
                </StackPanel>
                <Border Background="#EFE9DE" CornerRadius="10" Padding="3" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <StackPanel Orientation="Horizontal">
                    <Border x:Name="SegDark" CornerRadius="8" Padding="14,5" Background="#FFFFFF" Cursor="Hand">
                      <TextBlock x:Name="SegDarkTx" Text="暗色" FontSize="12" FontWeight="SemiBold" Foreground="#2A241E"/>
                    </Border>
                    <Border x:Name="SegLight" CornerRadius="8" Padding="14,5" Background="#00FFFFFF" Cursor="Hand">
                      <TextBlock x:Name="SegLightTx" Text="亮色" FontSize="12" FontWeight="SemiBold" Foreground="#8A8178"/>
                    </Border>
                  </StackPanel>
                </Border>
              </Grid>
              <Border Height="1" Background="#F0EAE0"/>
              <Grid Margin="0,10,0,10">
                <StackPanel Margin="0,0,56,0">
                  <TextBlock Text="系统硬件监控" FontSize="13" FontWeight="SemiBold" Foreground="#2A241E"/>
                  <TextBlock Text="空闲 30 秒后岛上显示 CPU / 内存占用,新事件立即让位" FontSize="11" Foreground="#8A8178" Margin="0,2,0,0"/>
                </StackPanel>
                <Border x:Name="SwHw" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                </Border>
              </Grid>
              <Border Height="1" Background="#F0EAE0"/>
              <Grid Margin="0,10,0,4">
                <StackPanel Margin="0,0,56,0">
                  <TextBlock Text="贴边隐藏" FontSize="13" FontWeight="SemiBold" Foreground="#2A241E"/>
                  <TextBlock Text="空闲 30 秒缩进屏幕顶边只留细条;悬停或新事件弹出" FontSize="11" Foreground="#8A8178" Margin="0,2,0,0"/>
                </StackPanel>
                <Border x:Name="SwEdge" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                </Border>
              </Grid>
            </StackPanel>
          </Border>
          <Border Background="#FFFFFF" BorderThickness="1" BorderBrush="#ECE6DB" CornerRadius="16" Padding="17,14" Margin="0,16,0,0">
            <StackPanel>
              <TextBlock Text="提示音效" FontSize="13" FontWeight="Bold" Foreground="#2A241E"/>
              <TextBlock Text="每个状态可配不同声音;▶ 试听(静默模式下试听也出声)" FontSize="11" Foreground="#8A8178" Margin="0,3,0,4"/>
              <Grid Margin="0,8,0,8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/><ColumnDefinition Width="34"/></Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Ellipse Width="8" Height="8" Fill="#2FA84F" VerticalAlignment="Center"/>
                  <TextBlock Text="任务完成" FontSize="12" FontWeight="SemiBold" Foreground="#2A241E" Margin="6,0,0,0"/>
                </StackPanel>
                <ComboBox Grid.Column="1" x:Name="SndDone" FontSize="11.5" VerticalAlignment="Center"/>
                <Border Grid.Column="2" x:Name="PlDone" Width="26" Height="24" CornerRadius="7" Background="#F2E8DA" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <TextBlock Text="▶" FontSize="10" Foreground="#E26934" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </Grid>
              <Border Height="1" Background="#F0EAE0"/>
              <Grid Margin="0,8,0,8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/><ColumnDefinition Width="34"/></Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Ellipse Width="8" Height="8" Fill="#2B7FD4" VerticalAlignment="Center"/>
                  <TextBlock Text="需要授权" FontSize="12" FontWeight="SemiBold" Foreground="#2A241E" Margin="6,0,0,0"/>
                </StackPanel>
                <ComboBox Grid.Column="1" x:Name="SndAuth" FontSize="11.5" VerticalAlignment="Center"/>
                <Border Grid.Column="2" x:Name="PlAuth" Width="26" Height="24" CornerRadius="7" Background="#F2E8DA" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <TextBlock Text="▶" FontSize="10" Foreground="#E26934" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </Grid>
              <Border Height="1" Background="#F0EAE0"/>
              <Grid Margin="0,8,0,8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/><ColumnDefinition Width="34"/></Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Ellipse Width="8" Height="8" Fill="#D64545" VerticalAlignment="Center"/>
                  <TextBlock Text="出错了" FontSize="12" FontWeight="SemiBold" Foreground="#2A241E" Margin="6,0,0,0"/>
                </StackPanel>
                <ComboBox Grid.Column="1" x:Name="SndErr" FontSize="11.5" VerticalAlignment="Center"/>
                <Border Grid.Column="2" x:Name="PlErr" Width="26" Height="24" CornerRadius="7" Background="#F2E8DA" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <TextBlock Text="▶" FontSize="10" Foreground="#E26934" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </Grid>
              <Border Height="1" Background="#F0EAE0"/>
              <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/><ColumnDefinition Width="34"/></Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Ellipse Width="8" Height="8" Fill="#E8A24A" VerticalAlignment="Center"/>
                  <TextBlock Text="等你回话" FontSize="12" FontWeight="SemiBold" Foreground="#2A241E" Margin="6,0,0,0"/>
                </StackPanel>
                <ComboBox Grid.Column="1" x:Name="SndWait" FontSize="11.5" VerticalAlignment="Center"/>
                <Border Grid.Column="2" x:Name="PlWait" Width="26" Height="24" CornerRadius="7" Background="#F2E8DA" Cursor="Hand" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <TextBlock Text="▶" FontSize="10" Foreground="#E26934" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </Grid>
            </StackPanel>
          </Border>
          </StackPanel>
          <StackPanel Grid.Column="2">
            <Border Background="#FFFFFF" BorderThickness="1" BorderBrush="#ECE6DB" CornerRadius="16" Padding="17,14">
              <StackPanel>
                <TextBlock Text="按状态静音" FontSize="13" FontWeight="Bold" Foreground="#2A241E"/>
                <TextBlock Text="被静音的状态只更新面板,不弹岛不出声" FontSize="11" Foreground="#8A8178" Margin="0,3,0,4"/>
                <Grid Margin="0,7,0,7">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Grid Width="32" Height="32"><Ellipse Fill="#FCFAF7"/><Ellipse><Ellipse.Fill><ImageBrush ImageSource="$bDone" Stretch="UniformToFill"/></Ellipse.Fill></Ellipse><Ellipse Stroke="#2FA84F" StrokeThickness="1.6"/></Grid>
                  <StackPanel Grid.Column="1" Margin="10,0,8,0" VerticalAlignment="Center">
                    <TextBlock Text="任务完成" FontSize="12.5" FontWeight="SemiBold" Foreground="#2A241E"/>
                    <TextBlock Text="Stop / SubagentStop" FontSize="10" Foreground="#8A8178"/>
                  </StackPanel>
                  <Ellipse Grid.Column="2" Width="8" Height="8" Fill="#2FA84F" VerticalAlignment="Center" Margin="0,0,9,0"/>
                  <Border Grid.Column="3" x:Name="SwMuteDone" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" VerticalAlignment="Center">
                    <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                  </Border>
                </Grid>
                <Border Height="1" Background="#F0EAE0"/>
                <Grid Margin="0,7,0,7">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Grid Width="32" Height="32"><Ellipse Fill="#FCFAF7"/><Ellipse><Ellipse.Fill><ImageBrush ImageSource="$bAuth" Stretch="UniformToFill"/></Ellipse.Fill></Ellipse><Ellipse Stroke="#2B7FD4" StrokeThickness="1.6"/></Grid>
                  <StackPanel Grid.Column="1" Margin="10,0,8,0" VerticalAlignment="Center">
                    <TextBlock Text="需要授权" FontSize="12.5" FontWeight="SemiBold" Foreground="#2A241E"/>
                    <TextBlock Text="PermissionRequest" FontSize="10" Foreground="#8A8178"/>
                  </StackPanel>
                  <Ellipse Grid.Column="2" Width="8" Height="8" Fill="#2B7FD4" VerticalAlignment="Center" Margin="0,0,9,0"/>
                  <Border Grid.Column="3" x:Name="SwMuteAuth" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" VerticalAlignment="Center">
                    <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                  </Border>
                </Grid>
                <Border Height="1" Background="#F0EAE0"/>
                <Grid Margin="0,7,0,7">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Grid Width="32" Height="32"><Ellipse Fill="#FCFAF7"/><Ellipse><Ellipse.Fill><ImageBrush ImageSource="$bErr" Stretch="UniformToFill"/></Ellipse.Fill></Ellipse><Ellipse Stroke="#D64545" StrokeThickness="1.6"/></Grid>
                  <StackPanel Grid.Column="1" Margin="10,0,8,0" VerticalAlignment="Center">
                    <TextBlock Text="出错了" FontSize="12.5" FontWeight="SemiBold" Foreground="#2A241E"/>
                    <TextBlock Text="PostToolUseFailure" FontSize="10" Foreground="#8A8178"/>
                  </StackPanel>
                  <Ellipse Grid.Column="2" Width="8" Height="8" Fill="#D64545" VerticalAlignment="Center" Margin="0,0,9,0"/>
                  <Border Grid.Column="3" x:Name="SwMuteErr" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" VerticalAlignment="Center">
                    <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                  </Border>
                </Grid>
                <Border Height="1" Background="#F0EAE0"/>
                <Grid Margin="0,7,0,7">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Grid Width="32" Height="32"><Ellipse Fill="#FCFAF7"/><Ellipse><Ellipse.Fill><ImageBrush ImageSource="$bWait" Stretch="UniformToFill"/></Ellipse.Fill></Ellipse><Ellipse Stroke="#E8A24A" StrokeThickness="1.6"/></Grid>
                  <StackPanel Grid.Column="1" Margin="10,0,8,0" VerticalAlignment="Center">
                    <TextBlock Text="等你回话" FontSize="12.5" FontWeight="SemiBold" Foreground="#2A241E"/>
                    <TextBlock Text="Notification · idle" FontSize="10" Foreground="#8A8178"/>
                  </StackPanel>
                  <Ellipse Grid.Column="2" Width="8" Height="8" Fill="#E8A24A" VerticalAlignment="Center" Margin="0,0,9,0"/>
                  <Border Grid.Column="3" x:Name="SwMuteWait" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" VerticalAlignment="Center">
                    <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                  </Border>
                </Grid>
                <Border Height="1" Background="#F0EAE0"/>
                <Grid Margin="0,7,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Grid Width="32" Height="32"><Ellipse Fill="#FCFAF7"/><Ellipse><Ellipse.Fill><ImageBrush ImageSource="$bIdle" Stretch="UniformToFill"/></Ellipse.Fill></Ellipse><Ellipse Stroke="#A89F95" StrokeThickness="1.6"/></Grid>
                  <StackPanel Grid.Column="1" Margin="10,0,8,0" VerticalAlignment="Center">
                    <TextBlock Text="空闲" FontSize="12.5" FontWeight="SemiBold" Foreground="#2A241E"/>
                    <TextBlock Text="就绪回落态" FontSize="10" Foreground="#8A8178"/>
                  </StackPanel>
                  <Ellipse Grid.Column="2" Width="8" Height="8" Fill="#A89F95" VerticalAlignment="Center" Margin="0,0,9,0"/>
                  <Border Grid.Column="3" x:Name="SwMuteIdle" Width="42" Height="23" CornerRadius="12" Background="#E4DCCF" Cursor="Hand" VerticalAlignment="Center">
                    <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                  </Border>
                </Grid>
              </StackPanel>
            </Border>
            <Border Background="#FFFFFF" BorderThickness="1" BorderBrush="#ECE6DB" CornerRadius="16" Padding="17,14" Margin="0,16,0,0">
              <StackPanel>
                <TextBlock Text="今日统计" FontSize="13" FontWeight="Bold" Foreground="#2A241E"/>
                <UniformGrid Columns="4" Margin="0,9,0,10">
                  <Border BorderThickness="1" BorderBrush="#ECE6DB" CornerRadius="12" Background="#FDFBF8" Padding="4,8" Margin="0,0,4,0">
                    <StackPanel>
                      <TextBlock x:Name="SnDone" Text="0" FontSize="19" FontWeight="Bold" Foreground="#2A241E" HorizontalAlignment="Center"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,3,0,0">
                        <Ellipse Width="7" Height="7" Fill="#2FA84F" VerticalAlignment="Center"/>
                        <TextBlock Text="完成" FontSize="10.5" Foreground="#8A8178" Margin="4,0,0,0"/>
                      </StackPanel>
                    </StackPanel>
                  </Border>
                  <Border BorderThickness="1" BorderBrush="#ECE6DB" CornerRadius="12" Background="#FDFBF8" Padding="4,8" Margin="0,0,4,0">
                    <StackPanel>
                      <TextBlock x:Name="SnErr" Text="0" FontSize="19" FontWeight="Bold" Foreground="#2A241E" HorizontalAlignment="Center"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,3,0,0">
                        <Ellipse Width="7" Height="7" Fill="#D64545" VerticalAlignment="Center"/>
                        <TextBlock Text="报错" FontSize="10.5" Foreground="#8A8178" Margin="4,0,0,0"/>
                      </StackPanel>
                    </StackPanel>
                  </Border>
                  <Border BorderThickness="1" BorderBrush="#ECE6DB" CornerRadius="12" Background="#FDFBF8" Padding="4,8" Margin="0,0,4,0">
                    <StackPanel>
                      <TextBlock x:Name="SnAuth" Text="0" FontSize="19" FontWeight="Bold" Foreground="#2A241E" HorizontalAlignment="Center"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,3,0,0">
                        <Ellipse Width="7" Height="7" Fill="#2B7FD4" VerticalAlignment="Center"/>
                        <TextBlock Text="授权" FontSize="10.5" Foreground="#8A8178" Margin="4,0,0,0"/>
                      </StackPanel>
                    </StackPanel>
                  </Border>
                  <Border BorderThickness="1" BorderBrush="#ECE6DB" CornerRadius="12" Background="#FDFBF8" Padding="4,8">
                    <StackPanel>
                      <TextBlock x:Name="SnWait" Text="0" FontSize="19" FontWeight="Bold" Foreground="#2A241E" HorizontalAlignment="Center"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,3,0,0">
                        <Ellipse Width="7" Height="7" Fill="#E8A24A" VerticalAlignment="Center"/>
                        <TextBlock Text="等待" FontSize="10.5" Foreground="#8A8178" Margin="4,0,0,0"/>
                      </StackPanel>
                    </StackPanel>
                  </Border>
                </UniformGrid>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                  <TextBlock Text="近 7 日事件量" FontSize="12" FontWeight="Bold" Foreground="#2A241E"/>
                  <TextBlock Text="含静音/暂停期间" FontSize="10.5" Foreground="#8A8178" Margin="8,1,0,0"/>
                </StackPanel>
                <Canvas x:Name="TrendCanvas" Width="286" Height="74" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </Grid>
      </StackPanel>
      <Border Background="#FDFBF8" CornerRadius="0,0,14,14" Padding="20,12" Margin="0,16,0,0" BorderThickness="0,1,0,0" BorderBrush="#ECE6DB">
        <Grid>
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="CLogBtn" Text="打开日志" FontSize="12" Foreground="#8A8178" Cursor="Hand"/>
            <TextBlock x:Name="CQuitBtn" Text="退出灵动岛" FontSize="12" Foreground="#8A8178" Cursor="Hand" Margin="18,0,0,0"/>
          </StackPanel>
          <TextBlock Text="claude-island · AI问老李" FontSize="11.5" Foreground="#A89F95" HorizontalAlignment="Right"/>
        </Grid>
      </Border>
    </StackPanel>
  </Border>
</Window>
"@
  $crd = New-Object System.Xml.XmlNodeReader $cxaml
  $script:CWin = [Windows.Markup.XamlReader]::Load($crd)
  foreach ($n in @('CTitleBar','CMin','CClose','CMasterLabel','SwMaster','SwAuto','SwSilent','VolSlider','VolVal','AlphaSlider','AlphaVal',
                   'SegDark','SegDarkTx','SegLight','SegLightTx','SwMuteDone','SwMuteAuth','SwMuteErr','SwMuteWait','SwMuteIdle',
                   'SnDone','SnErr','SnAuth','SnWait','TrendCanvas','CLogBtn','CQuitBtn',
                   'SndDone','SndAuth','SndErr','SndWait','PlDone','PlAuth','PlErr','PlWait','SwHw','SwEdge')) {
    $script:CW[$n] = $script:CWin.FindName($n)
  }
  # 标题栏:拖动 / 最小化 / 关闭
  $script:CW.CTitleBar.Add_MouseLeftButtonDown({ try { $script:CWin.DragMove() } catch {} })
  $script:CW.CMin.Add_MouseLeftButtonUp({ $script:CWin.WindowState = 'Minimized' })
  $script:CW.CClose.Add_MouseLeftButtonUp({ $script:CWin.Close() })
  $script:CWin.Add_Closed({ $script:CWin = $null; $script:CW = @{} })
  # 总开关 = 暂停弹窗(daemon 保活)
  $script:CW.SwMaster.Add_MouseLeftButtonUp({ $script:Config.paused = -not $script:Config.paused; Save-Config; Sync-Master })
  # 开机自启
  $script:CW.SwAuto.Add_MouseLeftButtonUp({ $on = -not (Test-AutoStart); Set-AutoStart $on; Sync-Switch $script:CW.SwAuto (Test-AutoStart) })
  # 静默
  $script:CW.SwSilent.Add_MouseLeftButtonUp({ $script:Config.silent = -not $script:Config.silent; Save-Config; Sync-Switch $script:CW.SwSilent $script:Config.silent })
  # 系统硬件监控
  $script:CW.SwHw.Add_MouseLeftButtonUp({
    $script:Config.hwMonitor = -not $script:Config.hwMonitor; Save-Config
    Sync-Switch $script:CW.SwHw $script:Config.hwMonitor
    if (-not $script:Config.hwMonitor -and $script:HwShowing) { $script:HwShowing = $false; $Title.Text = 'AI问老李'; $Sub.Text = '就绪' }
  })
  # 贴边隐藏
  $script:CW.SwEdge.Add_MouseLeftButtonUp({
    $script:Config.edgeHide = -not $script:Config.edgeHide; Save-Config
    Sync-Switch $script:CW.SwEdge $script:Config.edgeHide
    $script:LastWakeAt = [DateTime]::Now   # 刚开启不立刻缩,给30秒观察期
  })
  # 音量 / 不透明度
  $script:CW.VolSlider.Add_ValueChanged({
    if ($script:CWSyncing) { return }
    $v = [int]$script:CW.VolSlider.Value
    $script:CW.VolVal.Text = "$v%"; $script:Config.volume = $v / 100.0; Save-Config
  })
  $script:CW.AlphaSlider.Add_ValueChanged({
    if ($script:CWSyncing) { return }
    $v = [int]$script:CW.AlphaSlider.Value
    $script:CW.AlphaVal.Text = "$v%"; $script:Config.opacity = $v / 100.0; Save-Config; Apply-Style
  })
  # 主题
  $script:CW.SegDark.Add_MouseLeftButtonUp({ $script:Config.theme = 'dark'; Save-Config; Apply-Style; Sync-Seg })
  $script:CW.SegLight.Add_MouseLeftButtonUp({ $script:Config.theme = 'light'; Save-Config; Apply-Style; Sync-Seg })
  # 按状态静音
  $script:CW.SwMuteDone.Add_MouseLeftButtonUp({ Toggle-Mute 'done' $script:CW.SwMuteDone })
  $script:CW.SwMuteAuth.Add_MouseLeftButtonUp({ Toggle-Mute 'authorize' $script:CW.SwMuteAuth })
  $script:CW.SwMuteErr.Add_MouseLeftButtonUp({ Toggle-Mute 'error' $script:CW.SwMuteErr })
  $script:CW.SwMuteWait.Add_MouseLeftButtonUp({ Toggle-Mute 'waiting' $script:CW.SwMuteWait })
  $script:CW.SwMuteIdle.Add_MouseLeftButtonUp({ Toggle-Mute 'idle' $script:CW.SwMuteIdle })
  # 提示音效:下拉选择 + ▶ 试听(试听走用户显式动作,静默模式也出声)
  $script:CW.SndDone.Add_SelectionChanged({ if ($script:CWSyncing) { return } $it = $script:CW.SndDone.SelectedItem; if ($it) { $script:Config.sounds['done'] = "$($it.Tag)"; Save-Config } })
  $script:CW.SndAuth.Add_SelectionChanged({ if ($script:CWSyncing) { return } $it = $script:CW.SndAuth.SelectedItem; if ($it) { $script:Config.sounds['authorize'] = "$($it.Tag)"; Save-Config } })
  $script:CW.SndErr.Add_SelectionChanged({ if ($script:CWSyncing) { return } $it = $script:CW.SndErr.SelectedItem; if ($it) { $script:Config.sounds['error'] = "$($it.Tag)"; Save-Config } })
  $script:CW.SndWait.Add_SelectionChanged({ if ($script:CWSyncing) { return } $it = $script:CW.SndWait.SelectedItem; if ($it) { $script:Config.sounds['waiting'] = "$($it.Tag)"; Save-Config } })
  $script:CW.PlDone.Add_MouseLeftButtonUp({ Play-File (Resolve-SoundFile $script:Config.sounds['done']) })
  $script:CW.PlAuth.Add_MouseLeftButtonUp({ Play-File (Resolve-SoundFile $script:Config.sounds['authorize']) })
  $script:CW.PlErr.Add_MouseLeftButtonUp({ Play-File (Resolve-SoundFile $script:Config.sounds['error']) })
  $script:CW.PlWait.Add_MouseLeftButtonUp({ Play-File (Resolve-SoundFile $script:Config.sounds['waiting']) })
  # 底部
  $script:CW.CLogBtn.Add_MouseLeftButtonUp({
    if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } else { Start-Process explorer.exe $RunDir }
  })
  $script:CW.CQuitBtn.Add_MouseLeftButtonUp({ $win.Dispatcher.Invoke([action]{ $win.Close() }) })
  Sync-ConsoleUI
  $script:CWin.Show()
}

# ---- 托盘(RenderShot 自检实例不建托盘) ----
$tray = $null
if (-not $RenderShot) {
  $tray = New-Object System.Windows.Forms.NotifyIcon
  $icoPath = Join-Path $Assets 'bear-idle.png'
  try {
    if (Test-Path $icoPath) {
      $bm = New-Object System.Drawing.Bitmap $icoPath
      $tray.Icon = [System.Drawing.Icon]::FromHandle($bm.GetHicon())
    } else { $tray.Icon = [System.Drawing.SystemIcons]::Application }
  } catch { $tray.Icon = [System.Drawing.SystemIcons]::Application }
  $tray.Text = 'Claude 灵动岛'; $tray.Visible = $true
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miConsole = New-Object System.Windows.Forms.ToolStripMenuItem
  $miConsole.Text = '设置控制台…'
  $miConsole.Add_Click({ $win.Dispatcher.Invoke([action]{ Show-Console }) })
  [void]$menu.Items.Add($miConsole)
  $miSilent = New-Object System.Windows.Forms.ToolStripMenuItem
  $miSilent.Text = '静默(只弹不响)'; $miSilent.CheckOnClick = $true; $miSilent.Checked = $script:Config.silent
  $miSilent.Add_Click({ $script:Config.silent = $miSilent.Checked; Save-Config; Log "静默=$($miSilent.Checked)" })
  [void]$menu.Items.Add($miSilent)
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $miQuit = New-Object System.Windows.Forms.ToolStripMenuItem
  $miQuit.Text = '退出'; $miQuit.Add_Click({ $win.Dispatcher.Invoke([action]{ $win.Close() }) })
  [void]$menu.Items.Add($miQuit)
  # 托盘双击 = 打开控制台;菜单展开时刷新静默勾选(控制台改过要同步)
  $tray.Add_MouseDoubleClick({ $win.Dispatcher.Invoke([action]{ Show-Console }) })
  $menu.Add_Opening({ $miSilent.Checked = [bool]$script:Config.silent })
  $tray.ContextMenuStrip = $menu
}

# ---- 关闭清理 ----
$win.Add_Closed({
  try { $tray.Visible = $false; $tray.Dispose() } catch {}
  try { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue } catch {}
  Log "daemon 退出"
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

# 启动:注册渲染回调 → 显示 → 主线程直接载入就绪小熊 + 应用主题/不透明度 + 开呼吸 + 读一次最新事件
$win.Add_ContentRendered({ Handle-EventsFile })
Log "进入消息循环"
$win.Show()
Set-Bear 'idle'
Apply-Style
Start-Breathing

# ---- RenderShot 自检模式:渲染 pill(折叠/展开)+ 控制台成 PNG 后退出 ----
if ($RenderShot) {
  New-Item -ItemType Directory -Force $RenderShot | Out-Null
  $script:Config.silent = $true    # 自检不响铃
  Apply-Event @{ state = 'done'; title = '任务完成'; project = 'AI问老李'; sub = ''; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
  Set-Badge 3
  $win.UpdateLayout()
  Save-Shot $RootPanel (Join-Path $RenderShot 'pill-collapsed.png')
  Toggle-Panel
  $win.UpdateLayout()
  Save-Shot $RootPanel (Join-Path $RenderShot 'pill-expanded.png')
  # 硬件监控态(真实采样一次;先收起面板)
  Toggle-Panel
  $hw = Get-HwSample
  if ($hw) {
    Show-HwState $hw
    $win.UpdateLayout()
    Save-Shot $RootPanel (Join-Path $RenderShot 'pill-hw.png')
  }
  Show-Console
  $script:CWin.UpdateLayout()
  Save-Shot $script:CWin.Content (Join-Path $RenderShot 'console.png')
  $script:CWin.Close()
  $win.Close()
  exit 0
}

Handle-EventsFile
if ($ShowConsole) { Show-Console }
[System.Windows.Threading.Dispatcher]::Run()
