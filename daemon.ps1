# -*- coding: utf-8 -*-
# claude-island · daemon.ps1 —— WPF 桌面灵动岛 daemon(Windows PowerShell 5.1 / pwsh 皆可)
# 核心版:隐藏 STA 窗口 + 圆角 pill + 小熊状态头像 + 状态边框色 + 托盘 + FileSystemWatcher 吃事件 + 音效
# 用法:powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File daemon.ps1
# 调试:加 -Debug 参数会把事件处理写日志到 ~/.claude/hooks/claude-island/daemon.log
param([switch]$DebugLog)

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

# ---- 单实例锁 ----
if (Test-Path $PidFile) {
  $old = Get-Content $PidFile -ErrorAction SilentlyContinue
  if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) { Log "已有实例 $old,退出"; exit 0 }
}
$PID | Out-File -Encoding ASCII $PidFile
Log "daemon 启动 pid=$PID"

# ---- 状态色板(语义化,与小熊表情一一对应) ----
$Colors = @{
  idle      = '#A89F95'   # 灰·就绪(半眯眼)
  done      = '#2FA84F'   # 绿·完成(开心弯眼)
  authorize = '#2B7FD4'   # 蓝·需授权(举爪请示)
  waiting   = '#E8A24A'   # 琥珀·等待输入(歪头?)
  error     = '#D64545'   # 红·命令报错(捂脸懊恼)
}
$SoundOf = @{ chime = 'chime.mp3'; notification = 'notification.mp3'; error = 'error.mp3'; pop = 'pop.mp3' }

# ---- 配置(静默/音量/按状态静音;托盘可切换,也可手改 config.json) ----
$ConfigFile = Join-Path $RunDir 'config.json'
$script:Config = @{ silent = $false; volume = 0.6; muteStates = @() }
function Load-Config {
  if (Test-Path $ConfigFile) {
    try {
      $c = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($null -ne $c.silent)     { $script:Config.silent = [bool]$c.silent }
      if ($null -ne $c.volume)     { $script:Config.volume = [double]$c.volume }
      if ($null -ne $c.muteStates) { $script:Config.muteStates = @($c.muteStates) }
    } catch {}
  }
}
function Save-Config {
  try {
    $o = [pscustomobject]@{ silent = $script:Config.silent; volume = $script:Config.volume; muteStates = @($script:Config.muteStates) }
    [System.IO.File]::WriteAllText($ConfigFile, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
  } catch {}
}
Load-Config

# ---- XAML(折叠态 pill:小熊 + 状态边框 + 标题) ----
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight"
        WindowStartupLocation="Manual" ResizeMode="NoResize">
  <StackPanel x:Name="Root" TextElement.FontFamily="Microsoft YaHei UI">
    <!-- 折叠态胶囊 -->
    <Border x:Name="Pill" CornerRadius="26" Background="#F0161310" Padding="8,6,18,6" Margin="22,22,22,0"
            BorderThickness="1" BorderBrush="#26FFFFFF" TextElement.FontFamily="Microsoft YaHei UI"
            HorizontalAlignment="Center">
      <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="7" Opacity="0.5" Color="#000000"/></Border.Effect>
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
    <Border x:Name="Panel" Width="322" Margin="22,9,22,22" CornerRadius="20" Background="#F0161310"
            BorderThickness="1" BorderBrush="#26FFFFFF" HorizontalAlignment="Center" Visibility="Collapsed">
      <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="9" Opacity="0.55" Color="#000000"/></Border.Effect>
      <StackPanel>
        <Grid Margin="16,13,12,11">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="灵动岛" Foreground="#F6F1EA" FontSize="13.5" FontWeight="Bold"/>
            <Border Background="#1AFFFFFF" CornerRadius="9" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="PanelUnread" Text="0 条未读" Foreground="#B4A99D" FontSize="11"/>
            </Border>
          </StackPanel>
          <TextBlock x:Name="ClearBtn" Text="清空" Foreground="#8A8178" FontSize="12"
                     HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand"/>
        </Grid>
        <Border Height="1" Background="#12FFFFFF"/>
        <StackPanel x:Name="MsgList" Margin="7,6"/>
        <Border Height="1" Background="#12FFFFFF"/>
        <TextBlock x:Name="ReadAllBtn" Text="全部已读" Foreground="#CFC6BB" FontSize="12.5"
                   Margin="16,11" Cursor="Hand"/>
      </StackPanel>
    </Border>
  </StackPanel>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)
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

# ---- 播音效 ----
$script:Player = New-Object System.Windows.Media.MediaPlayer
function Play-Sound($key) {
  if (-not $key) { return }
  $f = Join-Path (Join-Path $Assets 'sfx') $SoundOf[$key]
  if (Test-Path $f) { try { $script:Player.Open([Uri]$f); $script:Player.Volume = [double]$script:Config.volume; $script:Player.Play() } catch { Log "音效失败 $_" } }
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
      <TextBlock Text="$title" Foreground="#F6F1EA" FontSize="13.5" FontWeight="SemiBold"/>
      <TextBlock Text="$meta" Foreground="#B4A99D" FontSize="11.5" Margin="0,2,0,0"/>
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
  if (-not $script:Config.silent) { Play-Sound "$($e.sound)" }
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

# ---- 托盘 ----
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
$miSilent = New-Object System.Windows.Forms.ToolStripMenuItem
$miSilent.Text = '静默(只弹不响)'; $miSilent.CheckOnClick = $true; $miSilent.Checked = $script:Config.silent
$miSilent.Add_Click({ $script:Config.silent = $miSilent.Checked; Save-Config; Log "静默=$($miSilent.Checked)" })
[void]$menu.Items.Add($miSilent)
$miConfig = New-Object System.Windows.Forms.ToolStripMenuItem
$miConfig.Text = '打开配置文件…'
$miConfig.Add_Click({ Save-Config; Start-Process notepad.exe $ConfigFile })
[void]$menu.Items.Add($miConfig)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit = New-Object System.Windows.Forms.ToolStripMenuItem
$miQuit.Text = '退出'; $miQuit.Add_Click({ $win.Dispatcher.Invoke([action]{ $win.Close() }) })
[void]$menu.Items.Add($miQuit)
$tray.ContextMenuStrip = $menu

# ---- 关闭清理 ----
$win.Add_Closed({
  try { $tray.Visible = $false; $tray.Dispose() } catch {}
  try { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue } catch {}
  Log "daemon 退出"
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

# 启动:注册渲染回调 → 显示 → 主线程直接载入就绪小熊 + 开呼吸 + 读一次最新事件
$win.Add_ContentRendered({ Handle-EventsFile })
Log "进入消息循环"
$win.Show()
Set-Bear 'idle'
Start-Breathing
Handle-EventsFile
[System.Windows.Threading.Dispatcher]::Run()
