# Claude Sessions Overlay
# A frameless, always-on-top WPF overlay that shows every running Claude Code
# session globally by reading ~/.claude/sessions/<pid>.json files.

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# Win32 helpers: enumerate top-level windows and focus one (restoring if minimized,
# using AttachThreadInput to bypass the foreground lock).
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WinInfo { public IntPtr Handle; public uint Pid; public string Title; }

public static class WinTools {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool altTab);
  [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint a, uint b, ref uint c, uint d);
  [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint a, uint b, IntPtr c, uint d);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

  // Make the overlay a no-activate window so clicking it never steals foreground.
  public static void SetNoActivate(IntPtr h) {
    int ex = GetWindowLong(h, -20);            // GWL_EXSTYLE
    SetWindowLong(h, -20, ex | 0x08000000);    // WS_EX_NOACTIVATE
  }

  public static WinInfo[] List() {
    var res = new List<WinInfo>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      var sb = new StringBuilder(len + 1);
      GetWindowText(h, sb, sb.Capacity);
      uint pid; GetWindowThreadProcessId(h, out pid);
      res.Add(new WinInfo { Handle = h, Pid = pid, Title = sb.ToString() });
      return true;
    }, IntPtr.Zero);
    return res.ToArray();
  }

  const uint SPI_GETFOREGROUNDLOCKTIMEOUT = 0x2000;
  const uint SPI_SETFOREGROUNDLOCKTIMEOUT = 0x2001;
  const uint SPIF_SENDCHANGE = 0x0002;

  public static void Focus(IntPtr h) {
    if (h == IntPtr.Zero) return;
    if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE

    // Disable the foreground lock for the duration of the call. Without this, once the
    // overlay has given focus away it loses the right to call SetForegroundWindow and
    // Windows silently blocks every later attempt (flashing the taskbar instead).
    uint oldTimeout = 0;
    SystemParametersInfo(SPI_GETFOREGROUNDLOCKTIMEOUT, 0, ref oldTimeout, 0);
    SystemParametersInfo(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, IntPtr.Zero, SPIF_SENDCHANGE);

    IntPtr fg = GetForegroundWindow();
    uint fgPid; uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
    uint cur = GetCurrentThreadId();
    bool attached = (fgThread != cur) && AttachThreadInput(cur, fgThread, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    SwitchToThisWindow(h, true);   // Alt-Tab mechanism; reliably activates, ignores the lock
    if (attached) AttachThreadInput(cur, fgThread, false);

    // Restore the user's original foreground-lock setting.
    SystemParametersInfo(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, (IntPtr)(long)oldTimeout, SPIF_SENDCHANGE);
  }
}
"@

# Virtual-desktop "follow" support via the public, build-stable IVirtualDesktopManager.
# We can't truly pin without undocumented per-build COM GUIDs, so instead we move the
# overlay onto the current desktop whenever it gets left behind -> it follows you
# everywhere, which is effectively "visible on all desktops".
Add-Type @"
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopManager {
  [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr w, out int onCur);
  [PreserveSig] int GetWindowDesktopId(IntPtr w, out Guid id);
  [PreserveSig] int MoveWindowToDesktop(IntPtr w, ref Guid id);
}
[ComImport, Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")] public class CVirtualDesktopManager { }

public static class VD {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  static IVirtualDesktopManager m;
  public static bool Ready { get { return m != null; } }
  static VD() { try { m = (IVirtualDesktopManager)new CVirtualDesktopManager(); } catch { m = null; } }

  // If the overlay was left on another desktop, move it to the one the user is now on.
  public static void Follow(IntPtr overlay) {
    if (m == null || overlay == IntPtr.Zero) return;
    int onCur;
    if (m.IsWindowOnCurrentVirtualDesktop(overlay, out onCur) != 0) return;
    if (onCur != 0) return;                       // already here
    IntPtr fg = GetForegroundWindow();
    if (fg == IntPtr.Zero || fg == overlay) return;
    Guid id;
    if (m.GetWindowDesktopId(fg, out id) != 0) return;
    if (id == Guid.Empty) return;
    try { m.MoveWindowToDesktop(overlay, ref id); } catch { }
  }
}
"@

# True Windows-side "show on all desktops": pin the window via the shell's internal
# IVirtualDesktopPinnedApps. Once pinned, Windows itself keeps it on every desktop —
# no polling. GUIDs/vtable below are for Windows 11 24H2/25H2 (build 261xx/262xx).
Add-Type @"
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IServiceProvider10 {
  [return: MarshalAs(UnmanagedType.IUnknown)] object QueryService(ref Guid service, ref Guid riid);
}
[ComImport, Guid("372E1D3B-38D3-42E4-A15B-8AB2B178F513"), InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
public interface IApplicationView { }
[ComImport, Guid("1841C6D7-4F9D-42C0-AF41-8747538F10E5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IApplicationViewCollection {
  int GetViews(out object array);
  int GetViewsByZOrder(out object array);
  int GetViewsByAppUserModelId(string id, out object array);
  int GetViewForHwnd(IntPtr hwnd, out IApplicationView view);
}
[ComImport, Guid("4CE81583-1E4C-4632-A621-07A53543148F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopPinnedApps {
  bool IsAppIdPinned(string appId);
  void PinAppID(string appId);
  void UnpinAppID(string appId);
  bool IsViewPinned(IApplicationView view);
  void PinView(IApplicationView view);
  void UnpinView(IApplicationView view);
}
public static class Pinner {
  static readonly Guid CLSID_ImmersiveShell = new Guid("C2F03A33-21F5-47FA-B4BB-156362A2F239");
  static readonly Guid CLSID_VDPinnedApps   = new Guid("B5A399E7-1C87-46B8-88E9-FC5747B171BD");
  static IServiceProvider10 Shell() {
    return (IServiceProvider10)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_ImmersiveShell));
  }
  static IApplicationViewCollection VC(IServiceProvider10 s) {
    Guid a = typeof(IApplicationViewCollection).GUID; Guid b = a;
    return (IApplicationViewCollection)s.QueryService(ref a, ref b);
  }
  static IVirtualDesktopPinnedApps PA(IServiceProvider10 s) {
    Guid a = CLSID_VDPinnedApps; Guid b = typeof(IVirtualDesktopPinnedApps).GUID;
    return (IVirtualDesktopPinnedApps)s.QueryService(ref a, ref b);
  }
  // Pin the window to all virtual desktops. Returns true if Windows now reports it pinned.
  public static bool Pin(IntPtr hwnd) {
    try {
      var s = Shell(); var vc = VC(s);
      IApplicationView view; int hr = vc.GetViewForHwnd(hwnd, out view);
      if (hr != 0 || view == null) return false;
      var pa = PA(s);
      if (!pa.IsViewPinned(view)) pa.PinView(view);
      return pa.IsViewPinned(view);
    } catch { return false; }
  }
  // Unpin the window from all virtual desktops. Returns true if Windows now reports it unpinned.
  public static bool Unpin(IntPtr hwnd) {
    try {
      var s = Shell(); var vc = VC(s);
      IApplicationView view; int hr = vc.GetViewForHwnd(hwnd, out view);
      if (hr != 0 || view == null) return false;
      var pa = PA(s);
      if (pa.IsViewPinned(view)) pa.UnpinView(view);
      return !pa.IsViewPinned(view);
    } catch { return false; }
  }
}
"@

$SessionsDir = Join-Path $env:USERPROFILE '.claude\sessions'
# needs_input markers written by scripts\session-attention.cjs (Notification hook).
# The native session JSON only ever carries busy/idle, so this sidecar is the sole
# source for the "Claude is waiting for the user" state.
$AttentionDir = Join-Path $env:USERPROFILE '.claude\session-attention'
$sep = [char]0x00B7   # middle dot, defined via char code so file encoding never mangles it

# Persisted "links": sessionId -> terminal window handle, for sessions whose window
# title can't be auto-matched (right-click a row to link it to the current terminal).
$LinksFile = Join-Path $PSScriptRoot 'links.json'
$script:Links = @{}
if (Test-Path $LinksFile) {
  try {
    (Get-Content $LinksFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
      $script:Links[$_.Name] = [int64]$_.Value
    }
  } catch {}
}
function Save-Links {
  try {
    $o = New-Object psobject
    foreach ($k in $script:Links.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $script:Links[$k] }
    $o | ConvertTo-Json -Compress | Set-Content -Path $LinksFile -Encoding UTF8
  } catch {}
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Sessions" Width="340" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" Left="40" Top="40">
  <Border CornerRadius="10" Background="#E6141414" BorderBrush="#33FFFFFF" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.5" Color="Black"/>
    </Border.Effect>
    <Grid>
      <DockPanel Margin="0">
        <!-- Header bar (drag handle) -->
        <Grid DockPanel.Dock="Top" x:Name="Header" Background="#00000000" Height="34">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="&#x25CF; Claude Sessions" Foreground="#FFE6A23C"
                     FontFamily="Segoe UI Semibold" FontSize="12" VerticalAlignment="Center"
                     Margin="12,0,0,0"/>
          <Slider Grid.Column="1" x:Name="OpacitySlider" Minimum="0.25" Maximum="1.0" Value="0.95"
                  Width="58" VerticalAlignment="Center" Margin="0,0,8,0"
                  ToolTip="Window opacity" IsMoveToPointEnabled="True"/>
          <TextBlock Grid.Column="2" x:Name="CountText" Text="" Foreground="#80FFFFFF"
                     FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <Button Grid.Column="3" x:Name="PinBtn" Content="&#x1F4CC;" Width="30" Height="30"
                  Foreground="#FFE6A23C" Background="Transparent" BorderThickness="0"
                  FontSize="13" Cursor="Hand" ToolTip="Pin on top / all desktops"/>
          <Button Grid.Column="4" x:Name="GifBtn" Content="GIF" Width="34" Height="30"
                  Foreground="#99FFFFFF" Background="Transparent" BorderThickness="0"
                  FontSize="11" Cursor="Hand" ToolTip="Configure status GIFs"/>
          <Button Grid.Column="5" x:Name="CloseBtn" Content="&#x2715;" Width="30" Height="30"
                  Foreground="#99FFFFFF" Background="Transparent" BorderThickness="0"
                  FontSize="13" Cursor="Hand"/>
        </Grid>
        <!-- Session list (scrolls when rows exceed the dragged height cap) -->
        <ScrollViewer x:Name="ListScroller" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled" MaxHeight="600">
          <ItemsControl x:Name="List" Margin="8,2,8,10"/>
        </ScrollViewer>
      </DockPanel>
      <!-- Right-edge handle for horizontal resizing (below the header). -->
      <Thumb x:Name="ResizeGrip" HorizontalAlignment="Right" Width="6" Margin="0,34,0,0" Cursor="SizeWE">
        <Thumb.Template>
          <ControlTemplate TargetType="Thumb">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Thumb.Template>
      </Thumb>
      <!-- Bottom-right corner handle for diagonal (width + height) resizing. -->
      <Thumb x:Name="ResizeGripBR" HorizontalAlignment="Right" VerticalAlignment="Bottom"
             Width="14" Height="14" Cursor="SizeNWSE">
        <Thumb.Template>
          <ControlTemplate TargetType="Thumb">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Thumb.Template>
      </Thumb>
    </Grid>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

$Header     = $Window.FindName('Header')
$List       = $Window.FindName('List')
$CloseBtn   = $Window.FindName('CloseBtn')
$CountText  = $Window.FindName('CountText')
$ResizeGrip = $Window.FindName('ResizeGrip')
$ResizeGripBR = $Window.FindName('ResizeGripBR')
$ListScroller = $Window.FindName('ListScroller')
$OpacitySlider = $Window.FindName('OpacitySlider')
$GifBtn     = $Window.FindName('GifBtn')
$PinBtn     = $Window.FindName('PinBtn')

# Persisted UI settings (width + opacity).
$UISettingsFile = Join-Path $PSScriptRoot 'settings.json'
$script:UI = @{ width = 340.0; opacity = 0.95; pinned = $true; listMaxHeight = 600.0 }

# Per-state GIF config. Each path is user-configured (a local file path, or a
# file:// / http(s) URL); an empty path means "no GIF for that state". The floating
# GIF window shows the GIF for the current overall Claude state, aggregated across all
# sessions with priority needs_input > running > idle. Empty default = feature off.
$script:Gif = @{
  enabled = $true
  paths   = @{ running = ''; needs_input = ''; idle = '' }
  win     = @{ left = 60.0; top = 360.0; width = 200.0; height = 200.0 }
}
if (Test-Path $UISettingsFile) {
  try {
    $cfg = Get-Content $UISettingsFile -Raw | ConvertFrom-Json
    if ($cfg.width)   { $script:UI.width   = [double]$cfg.width }
    if ($cfg.opacity) { $script:UI.opacity = [double]$cfg.opacity }
    if ($cfg.listMaxHeight) { $script:UI.listMaxHeight = [double]$cfg.listMaxHeight }
    if ($null -ne $cfg.pinned) { $script:UI.pinned = [bool]$cfg.pinned }
    # GIF settings are additive: missing keys fall back to the defaults above.
    if ($null -ne $cfg.gifEnabled) { $script:Gif.enabled = [bool]$cfg.gifEnabled }
    if ($cfg.gifPaths) {
      foreach ($k in 'running','needs_input','idle') {
        if ($cfg.gifPaths.$k) { $script:Gif.paths[$k] = [string]$cfg.gifPaths.$k }
      }
    }
    if ($cfg.gifWindow) {
      foreach ($k in 'left','top','width','height') {
        if ($null -ne $cfg.gifWindow.$k) { $script:Gif.win[$k] = [double]$cfg.gifWindow.$k }
      }
    }
  } catch {}
}
function Save-UISettings {
  try {
    [pscustomobject]@{
      width      = $Window.Width
      opacity    = $OpacitySlider.Value
      pinned     = $script:UI.pinned
      listMaxHeight = $ListScroller.MaxHeight
      gifEnabled = $script:Gif.enabled
      gifPaths   = [pscustomobject]$script:Gif.paths
      gifWindow  = [pscustomobject]$script:Gif.win
    } | ConvertTo-Json -Compress | Set-Content -Path $UISettingsFile -Encoding UTF8
  } catch {}
}

# Apply saved width + opacity.
$Window.Width = [Math]::Max(240, [Math]::Min(1000, $script:UI.width))
$ListScroller.MaxHeight = [Math]::Max(120, [Math]::Min(1200, $script:UI.listMaxHeight))
$OpacitySlider.Value = [Math]::Max(0.25, [Math]::Min(1.0, $script:UI.opacity))
$Window.Opacity = $OpacitySlider.Value
$Window.Topmost = $script:UI.pinned   # honor persisted pin state from first paint

# Drag the window from the header — but not when interacting with the opacity slider.
$Header.Add_MouseLeftButtonDown({
  $el = $_.OriginalSource
  while ($el) {
    if ($el -eq $OpacitySlider) { return }
    $el = if ($el -is [System.Windows.DependencyObject]) { [System.Windows.Media.VisualTreeHelper]::GetParent($el) } else { $null }
  }
  $Window.DragMove()
})
$CloseBtn.Add_Click({ $Window.Close() })

# Opacity slider -> window opacity.
$OpacitySlider.Add_ValueChanged({ $Window.Opacity = $_.NewValue })
$OpacitySlider.Add_PreviewMouseUp({ Save-UISettings })

# Right-edge grip -> horizontal resize.
$ResizeGrip.Add_DragDelta({
  $w = $Window.Width + $_.HorizontalChange
  $Window.Width = [Math]::Max(240, [Math]::Min(1000, $w))
})
$ResizeGrip.Add_DragCompleted({ Save-UISettings })

# Bottom-right corner grip -> diagonal resize (width + list height cap).
$ResizeGripBR.Add_DragDelta({
  $w = $Window.Width + $_.HorizontalChange
  $Window.Width = [Math]::Max(240, [Math]::Min(1000, $w))
  $h = $ListScroller.MaxHeight + $_.VerticalChange
  $ListScroller.MaxHeight = [Math]::Max(120, [Math]::Min(1200, $h))
})
$ResizeGripBR.Add_DragCompleted({ Save-UISettings })

# Capture the handle and make the overlay a no-activate window (never steals focus).
$Window.Add_SourceInitialized({
  $script:overlayHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
  if ($script:overlayHwnd -ne [IntPtr]::Zero) { [WinTools]::SetNoActivate($script:overlayHwnd) }
})

function Get-AliveProcessIds {
  $set = @{}
  foreach ($p in Get-Process -ErrorAction SilentlyContinue) { $set[$p.Id] = $true }
  return $set
}

function Format-Age([long]$ms) {
  if ($ms -le 0) { return 'now' }
  $s = [int]($ms / 1000)
  if ($s -lt 60)    { return "${s}s" }
  $m = [int]($s / 60)
  if ($m -lt 60)    { return "${m}m" }
  $h = [int]($m / 60)
  if ($h -lt 24)    { return "${h}h" }
  $d = [int]($h / 24)
  return "${d}d"
}

# Read a session's transcript tail and summarise what it's currently doing, the most
# recent user prompt, and the model in use. Cached per session keyed on updatedAt, so
# idle sessions aren't re-parsed every tick.
# Returns @{ activity = <what it's doing>; prompt = <last user prompt>; model = <model id> }.
$script:ActivityCache = @{}
function Get-SessionActivity($cwd, $sessionId, $updatedAt) {
  $empty = @{ activity = ''; prompt = ''; model = '' }
  if (-not $sessionId -or -not $cwd) { return $empty }
  $cached = $script:ActivityCache[$sessionId]
  if ($cached -and $cached.upd -eq $updatedAt) { return $cached.val }

  $enc  = ($cwd -replace '[^A-Za-z0-9]', '-')
  $path = Join-Path $env:USERPROFILE ".claude\projects\$enc\$sessionId.jsonl"
  $val  = @{ activity = ''; prompt = ''; model = '' }
  if (Test-Path $path) {
    try {
      $lastUser = ''; $lastAsst = ''; $lastTool = ''; $lastModel = ''
      foreach ($ln in (Get-Content -Path $path -Tail 80 -Encoding UTF8 -ErrorAction Stop)) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        try { $d = $ln | ConvertFrom-Json } catch { continue }
        $m = $d.message
        if (-not $m) { continue }
        $c = $m.content
        if ($m.role -eq 'user') {
          $t = $null
          if ($c -is [string]) { $t = $c }
          elseif ($c) { foreach ($b in $c) { if ($b.type -eq 'text') { $t = $b.text; break } } }
          if ($t -and -not $t.StartsWith('<') -and -not $t.StartsWith('Caveat') -and $t -notmatch 'tool_result') { $lastUser = $t }
        }
        elseif ($m.role -eq 'assistant' -and $c) {
          if ($m.model) { $lastModel = "$($m.model)" }    # model can change mid-session; last wins
          foreach ($b in $c) {
            if ($b.type -eq 'text' -and "$($b.text)".Trim()) { $lastAsst = $b.text }
            elseif ($b.type -eq 'tool_use') { $lastTool = $b.name }
          }
        }
      }
      $act = if ($lastAsst) { $lastAsst } elseif ($lastUser) { $lastUser } elseif ($lastTool) { "running $lastTool" } else { '' }
      $act = ($act -replace '\s+', ' ').Trim()
      if ($act.Length -gt 200) { $act = $act.Substring(0, 200) }
      $prompt = ($lastUser -replace '\s+', ' ').Trim()
      if ($prompt.Length -gt 200) { $prompt = $prompt.Substring(0, 200) }
      $val = @{ activity = $act; prompt = $prompt; model = $lastModel }
    } catch {}
  }
  $script:ActivityCache[$sessionId] = @{ upd = $updatedAt; val = $val }
  return $val
}

# Shorten a model id for display: "claude-opus-4-8" -> "opus 4.8",
# "claude-sonnet-4-6" -> "sonnet 4.6", "claude-haiku-4-5-20251001" -> "haiku 4.5".
function Format-Model([string]$m) {
  if (-not $m) { return '' }
  $x = $m -replace '^claude-', '' -replace '-\d{8}$', ''   # strip prefix + trailing date stamp
  if ($x -match '^([a-z]+)-(\d+)-(\d+)') { return "$($matches[1]) $($matches[2]).$($matches[3])" }
  return $x
}

# Token consumption per session. Sums message.usage across the whole transcript
# (input + cache-create + cache-read + output) and also tracks the latest turn's
# prompt size as the current context-window fill. Reads incrementally: the cache
# remembers the byte offset already parsed, so each 2s tick only scans newly
# appended lines (transcripts are append-only JSONL) instead of re-summing the file.
$script:TokenCache = @{}
function Get-SessionTokens($cwd, $sessionId) {
  if (-not $sessionId -or -not $cwd) { return $null }
  $enc  = ($cwd -replace '[^A-Za-z0-9]', '-')
  $path = Join-Path $env:USERPROFILE ".claude\projects\$enc\$sessionId.jsonl"
  if (-not (Test-Path $path)) { return $null }
  try { $len = (Get-Item $path).Length } catch { return $null }

  $c = $script:TokenCache[$sessionId]
  if (-not $c) {
    $c = @{ size = 0L; inTok = 0L; cacheCreate = 0L; cacheRead = 0L; outTok = 0L; ctx = 0L }
    $script:TokenCache[$sessionId] = $c
  }
  if ($len -eq $c.size) { return $c }                       # nothing appended since last tick
  if ($len -lt $c.size) {                                   # file rotated/compacted -> reparse
    $c.size = 0L; $c.inTok = 0L; $c.cacheCreate = 0L; $c.cacheRead = 0L; $c.outTok = 0L; $c.ctx = 0L
  }

  try {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $null = $fs.Seek($c.size, [System.IO.SeekOrigin]::Begin) # resume at the first un-parsed byte (a line boundary)
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    while (($ln = $sr.ReadLine()) -ne $null) {
      if ([string]::IsNullOrWhiteSpace($ln)) { continue }
      try { $d = $ln | ConvertFrom-Json } catch { continue }
      $u = $d.message.usage
      if (-not $u) { continue }
      $it = [long]($u.input_tokens); $ci = [long]($u.cache_creation_input_tokens)
      $cr = [long]($u.cache_read_input_tokens); $ot = [long]($u.output_tokens)
      $c.inTok += $it; $c.cacheCreate += $ci; $c.cacheRead += $cr; $c.outTok += $ot
      $c.ctx = $it + $ci + $cr                              # latest turn wins = current window fill
    }
    $sr.Close(); $fs.Close()
    $c.size = $len
  } catch {}
  return $c
}

# Compact human token count: 945 -> "945", 12_300 -> "12.3K", 3_450_000 -> "3.45M".
function Format-Tokens([long]$n) {
  if ($n -le 0)        { return '0' }
  if ($n -lt 1000)     { return "$n" }
  if ($n -lt 1000000)  { return ('{0:0.0}K' -f ($n / 1000.0)) }
  return ('{0:0.00}M' -f ($n / 1000000.0))
}

# Score how well a Windows Terminal tab/window title identifies a session.
# Returns 100 when the title contains the exact folder name at a word boundary,
# else 0. The boundary guard is essential: "Foo_IdleRPG" must NOT match the window
# of "Foo_IdleRPG2". A 0 means no identifying signal (e.g. generic "Claude Code").
function Get-TitleScore($title, $folder) {
  if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($folder)) { return 0 }
  $t = $title.ToLower()
  $f = [regex]::Escape($folder.ToLower())
  if ($t -match "(?<![a-z0-9])$f(?![a-z0-9])") { return 100 }
  return 0
}

function Test-LiveWindow($h) {
  foreach ($w in [WinTools]::List()) { if ($w.Handle -eq $h) { return $true } }
  return $false
}

# Briefly tint a row (red = failure, green = linked), then restore.
function Show-RowFlash($row, $hex) {
  $row.Background = [Windows.Media.BrushConverter]::new().ConvertFrom($hex)
  $ft = New-Object System.Windows.Threading.DispatcherTimer
  $ft.Interval = [TimeSpan]::FromMilliseconds(700)
  $ft.Add_Tick({
    # Restore the row's status tint (falls back to a neutral gray if unset).
    $restore = if ($row.Tag -and $row.Tag.BaseBg) { $row.Tag.BaseBg } else { '#386E7681' }
    $row.Background = [Windows.Media.BrushConverter]::new().ConvertFrom($restore)
    $this.Stop()
  }.GetNewClosure())
  $ft.Start()
}

# Resolve and focus the terminal for a session.
#   $cwd       disambiguates Windows Terminal windows/tabs by title.
#   $sessionId looks up a user-created link (right-click) when the title can't be matched.
function Focus-Session($sessionPid, $cwd, $sessionId) {
  $sessionPid = [int]$sessionPid
  $folder = if ($cwd) { Split-Path $cwd -Leaf } else { '' }

  # Prefer an explicit user link if it still points to a live window.
  if ($sessionId -and $script:Links.ContainsKey($sessionId)) {
    $lh = [IntPtr]([int64]$script:Links[$sessionId])
    if ((Test-LiveWindow $lh)) { [WinTools]::Focus($lh); return $true }
    $script:Links.Remove($sessionId); Save-Links            # stale -> forget it
  }

  # Build a child -> parent process map and a pid -> name map once.
  $parent = @{}; $pname = @{}
  foreach ($pr in Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) {
    $parent[[int]$pr.ProcessId] = [int]$pr.ParentProcessId
    $pname[[int]$pr.ProcessId] = "$($pr.Name)"
  }

  # Ancestor chain of the session (incl. itself).
  $anc = @{}; $c = $sessionPid; $g = 0
  $isWT = $false
  while ($c -gt 0 -and -not $anc.ContainsKey($c) -and $g -lt 24) {
    $anc[$c] = $true
    if ($pname[$c] -eq 'WindowsTerminal.exe') { $isWT = $true }
    $c = if ($parent.ContainsKey($c)) { $parent[$c] } else { 0 }
    $g++
  }

  # --- Non-Windows-Terminal terminals: process tree is reliable (one window per console). ---
  if (-not $isWT) {
    $match = [IntPtr]::Zero
    foreach ($w in [WinTools]::List()) {
      $wp = [int]$w.Pid
      if ($anc.ContainsKey($wp)) { $match = $w.Handle; break }   # window owned by an ancestor
      $cc = $wp; $gg = 0                                          # or by a descendant (legacy conhost)
      while ($cc -gt 0 -and $gg -lt 24) {
        if ($cc -eq $sessionPid) { $match = $w.Handle; break }
        $cc = if ($parent.ContainsKey($cc)) { $parent[$cc] } else { 0 }
        $gg++
      }
      if ($match -ne [IntPtr]::Zero) { break }
    }
    if ($match -ne [IntPtr]::Zero) { [WinTools]::Focus($match); return $true }
    return $false
  }

  # --- Windows Terminal: one process hosts every window+tab. Win32 EnumWindows sees
  # every WT window (incl. minimized / other virtual desktop) which UIA's RootElement
  # children query misses, so enumerate windows there and match by title. ---
  $wtPidSet = @{}
  foreach ($p in (Get-Process WindowsTerminal -ErrorAction SilentlyContinue)) { $wtPidSet[[int]$p.Id] = $true }

  $cands = @()
  foreach ($w in [WinTools]::List()) { if ($wtPidSet.ContainsKey([int]$w.Pid)) { $cands += $w } }

  $best = $null; $bestScore = 0
  foreach ($w in $cands) {
    $s = Get-TitleScore $w.Title $folder
    if ($s -gt $bestScore) { $bestScore = $s; $best = $w }
  }

  # Confident match: window title identifies the folder (>=30 = strong token overlap).
  if ($best -and $bestScore -ge 30) {
    [WinTools]::Focus($best.Handle)
    Select-WTTabInWindow $best.Handle $folder    # drill into the right tab if multi-tab
    return $true
  }
  # Exactly one WT window total -> unambiguous.
  if ($cands.Count -eq 1) { [WinTools]::Focus($cands[0].Handle); return $true }

  # Can't identify it (e.g. a generic "Claude Code" title shared by idle sessions).
  # Refuse to guess and jump to the wrong window.
  return $false
}

# Within an already-matched WT window, select the tab whose title best fits the folder.
function Select-WTTabInWindow($hwnd, $folder) {
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd)
    if (-not $el) { return }
    $tabType = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::TabItem)
    $tabs = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabType)
    if ($tabs.Count -le 1) { return }
    $bt = $null; $bs = 0
    foreach ($t in $tabs) {
      $s = Get-TitleScore $t.Current.Name $folder
      if ($s -gt $bs) { $bs = $s; $bt = $t }
    }
    if ($bt -and $bs -gt 0) {
      $sip = $bt.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
      [void]$sip.Select()
    }
  } catch {}
}

# Map a session status to its row background tint (base + hover shades). Replaces the
# old status dot — the whole row is tinted by status instead.
function Get-RowTint($color) {
  switch ($color) {
    'busy'        { return @{ base = '#2E3FB950'; hover = '#4D3FB950' } }   # green  = running
    'needs_input' { return @{ base = '#38D29922'; hover = '#57D29922' } }   # yellow = waiting for input
    'stale'       { return @{ base = '#33F85149'; hover = '#52F85149' } }   # red    = process ended
    'idle'        { return @{ base = '#386E7681'; hover = '#576E7681' } }   # gray   = idle
    default       { return @{ base = '#386E7681'; hover = '#57D29922' } }
  }
}

# Build a row once and return a hashtable of the Border plus references to every
# element whose content changes per tick. The row is then reused across refreshes
# (see Update-List) and only its text/colors are updated in place via Set-RowData —
# never destroyed and rebuilt. That is what keeps the hover background from blinking:
# the element under the cursor stays in the visual tree, so its MouseEnter state holds.
function New-Row {
  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = '7'
  $border.Margin = '0,3,0,0'
  $border.Padding = '10,7,10,7'
  # Default tint until Set-RowData re-tints by status (New-Row is a parameterless
  # template; per-session content/colour is filled in by Set-RowData each tick).
  $border.Background = [Windows.Media.BrushConverter]::new().ConvertFrom('#386E7681')
  $border.Cursor = 'Hand'

  # Left-click focuses the session's terminal; right-click links it to the current terminal.
  $border.Add_MouseLeftButtonUp({
    $t = $this.Tag
    if ($t -and $t.Pid) {
      $ok = Focus-Session $t.Pid $t.Cwd $t.SessionId
      if (-not $ok) { Show-RowFlash $this '#55F56C6C' }   # red: couldn't locate; right-click to link
    }
  })

  # Right-click: link this session to whatever terminal is currently focused.
  # (The overlay is no-activate, so the foreground window is the terminal you came from.)
  $border.Add_MouseRightButtonUp({
    $t = $this.Tag
    if ($t -and $t.SessionId) {
      $fg = [WinTools]::GetForegroundWindow()
      if ($fg -ne [IntPtr]::Zero -and $fg -ne $script:overlayHwnd) {
        $script:Links[$t.SessionId] = $fg.ToInt64()
        Save-Links
        Show-RowFlash $this '#5567C23A'                   # green: linked
      } else {
        Show-RowFlash $this '#55F56C6C'
      }
    }
  })

  $border.Add_MouseEnter({ $this.Background = [Windows.Media.BrushConverter]::new().ConvertFrom($this.Tag.HoverBg) })
  $border.Add_MouseLeave({ $this.Background = [Windows.Media.BrushConverter]::new().ConvertFrom($this.Tag.BaseBg) })

  $grid = New-Object System.Windows.Controls.Grid
  $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = '*'
  $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
  $grid.ColumnDefinitions.Add($c0)
  $grid.ColumnDefinitions.Add($c1)

  $stack = New-Object System.Windows.Controls.StackPanel
  [Windows.Controls.Grid]::SetColumn($stack, 0)

  $name = New-Object System.Windows.Controls.TextBlock
  $name.FontFamily = 'Segoe UI Semibold'
  $name.FontSize = 12
  $name.TextTrimming = 'CharacterEllipsis'
  $runName = New-Object System.Windows.Documents.Run
  $runName.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FFFFFFFF')
  $runPid = New-Object System.Windows.Documents.Run
  $runPid.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#80FFFFFF')
  $runPid.FontFamily = 'Segoe UI'
  $runPid.FontSize = 11
  $name.Inlines.Add($runName)
  $name.Inlines.Add($runPid)
  $stack.Children.Add($name) | Out-Null

  # Most recent user prompt — always built, collapsed when empty so the row's element
  # structure stays stable across refreshes (no add/remove churn under the cursor).
  $promptTb = New-Object System.Windows.Controls.TextBlock
  $promptTb.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#99E6A23C')
  $promptTb.FontFamily = 'Segoe UI'
  $promptTb.FontStyle = 'Italic'
  $promptTb.FontSize = 10
  $promptTb.TextTrimming = 'CharacterEllipsis'
  $stack.Children.Add($promptTb) | Out-Null

  $sub = New-Object System.Windows.Controls.TextBlock
  $sub.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#80FFFFFF')
  $sub.FontFamily = 'Segoe UI'
  $sub.FontSize = 10
  $sub.TextTrimming = 'CharacterEllipsis'
  $stack.Children.Add($sub) | Out-Null

  # Model + CLI version (e.g. "opus 4.8 · v2.1.170"), dim. Collapsed when unknown.
  $meta = New-Object System.Windows.Controls.TextBlock
  $meta.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#807AC2FF')
  $meta.FontFamily = 'Segoe UI'
  $meta.FontSize = 10
  $meta.TextTrimming = 'CharacterEllipsis'
  $stack.Children.Add($meta) | Out-Null

  # Right column: age on top, cumulative token consumption below.
  $right = New-Object System.Windows.Controls.StackPanel
  $right.VerticalAlignment = 'Center'
  $right.Margin = '8,0,0,0'
  [Windows.Controls.Grid]::SetColumn($right, 1)

  $age = New-Object System.Windows.Controls.TextBlock
  $age.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#66FFFFFF')
  $age.FontFamily = 'Segoe UI'
  $age.FontSize = 10
  $age.HorizontalAlignment = 'Right'

  # Current context-window fill (live), brighter blue.
  $ctx = New-Object System.Windows.Controls.TextBlock
  $ctx.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#CC6CB6FF')
  $ctx.FontFamily = 'Segoe UI'
  $ctx.FontSize = 10
  $ctx.HorizontalAlignment = 'Right'

  # Cumulative token throughput for the whole session, dimmer blue.
  $tok = New-Object System.Windows.Controls.TextBlock
  $tok.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#80A6D4FF')
  $tok.FontFamily = 'Segoe UI'
  $tok.FontSize = 10
  $tok.HorizontalAlignment = 'Right'

  $right.Children.Add($age) | Out-Null
  $right.Children.Add($ctx) | Out-Null
  $right.Children.Add($tok) | Out-Null

  $grid.Children.Add($stack) | Out-Null
  $grid.Children.Add($right) | Out-Null
  $border.Child = $grid

  return @{
    Border = $border; RunName = $runName; RunPid = $runPid
    Prompt = $promptTb; Sub = $sub; Meta = $meta; Age = $age; Ctx = $ctx; Tok = $tok
  }
}

# Update an existing row's content in place from session data $r. Only writes a
# property when it actually changed, so unchanged rows incur no layout work and the
# row under the cursor is never disturbed. Background is intentionally untouched so
# the hover tint (set by MouseEnter/Leave) survives every refresh.
function Set-RowData($e, $r) {
  # Status -> row background tint (replaces the old dot). Carry base/hover on the Tag so
  # the MouseEnter/Leave handlers (and Show-RowFlash) restore the right shade.
  $tint = Get-RowTint $r.color
  $e.Border.Tag = [pscustomobject]@{ Pid = $r.pid; Cwd = $r.cwd; SessionId = $r.sessionId; BaseBg = $tint.base; HoverBg = $tint.hover }
  if ($e.Border.ToolTip -ne $r.tip) { $e.Border.ToolTip = $r.tip }

  # Re-apply the background only when the tint or hover state actually changed, so an
  # unchanged row never churns its brush (keeps the in-place update blink-free).
  $bg = if ($e.Border.IsMouseOver) { $tint.hover } else { $tint.base }
  if ($e.LastBg -ne $bg) { $e.LastBg = $bg; $e.Border.Background = [Windows.Media.BrushConverter]::new().ConvertFrom($bg) }

  if ($e.RunName.Text -ne $r.name)      { $e.RunName.Text = $r.name }
  $pidTxt = "  $($r.pid)"
  if ($e.RunPid.Text -ne $pidTxt)       { $e.RunPid.Text = $pidTxt }

  if ($r.prompt) {
    if ($e.Prompt.Text -ne $r.prompt)   { $e.Prompt.Text = $r.prompt }
    if ($e.Prompt.Visibility -ne 'Visible') { $e.Prompt.Visibility = 'Visible' }
  } elseif ($e.Prompt.Visibility -ne 'Collapsed') {
    $e.Prompt.Visibility = 'Collapsed'
  }

  if ($e.Sub.Text -ne $r.sub)           { $e.Sub.Text = $r.sub }

  if ($r.metaTxt) {
    if ($e.Meta.Text -ne $r.metaTxt)    { $e.Meta.Text = $r.metaTxt }
    if ($e.Meta.Visibility -ne 'Visible') { $e.Meta.Visibility = 'Visible' }
  } elseif ($e.Meta.Visibility -ne 'Collapsed') {
    $e.Meta.Visibility = 'Collapsed'
  }

  if ($e.Age.Text -ne $r.age)           { $e.Age.Text = $r.age }
  if ($e.Ctx.Text -ne $r.ctxTxt)        { $e.Ctx.Text = $r.ctxTxt }
  if ($e.Tok.Text -ne $r.tokTxt)        { $e.Tok.Text = $r.tokTxt }
  if ($e.Ctx.ToolTip -ne $r.tokTip)     { $e.Ctx.ToolTip = $r.tokTip }
  if ($e.Tok.ToolTip -ne $r.tokTip)     { $e.Tok.ToolTip = $r.tokTip }
}

# Reused row elements, keyed by sessionId, so a session's row is built once and then
# updated in place every tick rather than recreated (prevents the hover blink).
$script:RowMap = @{}

function Update-List {
  if (-not (Test-Path $SessionsDir)) {
    foreach ($e in $script:RowMap.Values) { [void]$List.Items.Remove($e.Border) }
    $script:RowMap.Clear()
    $CountText.Text = '0'
    $script:OverallState = 'idle'
    return
  }
  $alive = Get-AliveProcessIds
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $rows = @()
  $nativeSids = @{}   # sessionIds seen this tick, for reaping orphaned attention markers

  foreach ($file in Get-ChildItem -Path $SessionsDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    try { $s = Get-Content $file.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not $s.pid) { continue }

    $isAlive = $alive.ContainsKey([int]$s.pid)
    $proj = if ($s.cwd) { Split-Path $s.cwd -Leaf } else { 'unknown' }
    if ([string]::IsNullOrWhiteSpace($proj)) { $proj = $s.cwd }

    if (-not $isAlive) {
      $color = 'stale'; $statusTxt = 'ended'
    } else {
      $color = $s.status
      $statusTxt = $s.status
    }

    # needs_input is a refinement of the idle state. The native session file only ever
    # carries busy/idle; the Notification hook (scripts\session-attention.cjs) drops a
    # marker when Claude is waiting for the user. Show needs_input when an ALIVE session
    # is NOT busy and has a marker. We deliberately do NOT compare timestamps: the native
    # updatedAt is a heartbeat that keeps advancing while a session runs (verified), so a
    # "marker newer than updatedAt" test would be raced by the heartbeat. The rule is
    # purely state-based — a busy (working) or dead session can't need input, so its
    # marker is reaped on sight, which also self-heals a missed `clear`.
    if ($s.sessionId) {
      $nativeSids[$s.sessionId] = $true
      $mk = Join-Path $AttentionDir "$($s.sessionId).json"
      if (Test-Path $mk) {
        if ($isAlive -and $s.status -ne 'busy') {
          $color = 'needs_input'; $statusTxt = 'needs input'
        } else {
          Remove-Item $mk -ErrorAction SilentlyContinue   # busy or dead: can't need input
        }
      }
    }

    $age = Format-Age ($now - [long]$s.updatedAt)

    $act = if ($isAlive) { Get-SessionActivity $s.cwd $s.sessionId $s.updatedAt } else { @{ activity = ''; prompt = ''; model = '' } }
    $activity = $act.activity
    $prompt   = $act.prompt
    $sub = if ($activity) { $activity } else { "$statusTxt $sep pid $($s.pid)" }

    # Model (from transcript) + CLI version (from session JSON). Effort/reasoning level
    # is not recorded anywhere in the session or transcript, so it can't be shown.
    $modelTxt  = Format-Model $act.model
    $ver       = "$($s.version)"
    $metaParts = @()
    if ($modelTxt) { $metaParts += $modelTxt }
    if ($ver)      { $metaParts += "v$ver" }
    $metaTxt   = ($metaParts -join " $sep ")
    $tip = "pid $($s.pid) $sep v$($s.version) $sep $statusTxt`n$($s.cwd)" +
      $(if ($prompt)   { "`n`nprompt: $prompt" } else { '' }) +
      $(if ($activity) { "`n`n$activity" } else { '' })

    # Token consumption (cumulative throughput across the session + current context fill).
    $tk = Get-SessionTokens $s.cwd $s.sessionId
    $total = 0L; $tokTxt = ''; $ctxTxt = ''; $tokTip = ''
    if ($tk) {
      $total  = [long]$tk.inTok + [long]$tk.cacheCreate + [long]$tk.cacheRead + [long]$tk.outTok
      $ctxTxt = if ([long]$tk.ctx -gt 0) { 'ctx ' + (Format-Tokens $tk.ctx) } else { '' }
      $tokTxt = if ($total -gt 0) { ([char]0x03A3) + ' ' + (Format-Tokens $total) } else { '' }   # Σ = cumulative
      $tokTip = "tokens this session" +
        "`n  context now : $(Format-Tokens $tk.ctx)" +
        "`n  output      : $(Format-Tokens $tk.outTok)" +
        "`n  input       : $(Format-Tokens $tk.inTok)" +
        "`n  cache write : $(Format-Tokens $tk.cacheCreate)" +
        "`n  cache read  : $(Format-Tokens $tk.cacheRead)" +
        "`n  total       : $(Format-Tokens $total)"
    }

    $rows += [pscustomobject]@{
      pid       = [int]$s.pid
      cwd       = "$($s.cwd)"
      sessionId = "$($s.sessionId)"
      name   = $proj
      prompt = $prompt
      sub    = $sub
      metaTxt = $metaTxt
      tip    = $tip
      age    = $age
      color  = $color
      alive  = $isAlive
      busy   = ($s.status -eq 'busy')
      upd    = [long]$s.updatedAt
      ctxTxt = $ctxTxt
      tokTxt = $tokTxt
      tokTip = $tokTip
      total  = $total
    }
  }

  # Reap orphaned attention markers whose native session file is gone entirely (the
  # per-row reap above only covers sessions still present in $SessionsDir). Keeps
  # ~/.claude/session-attention from growing without bound across many sessions.
  if (Test-Path $AttentionDir) {
    foreach ($mf in Get-ChildItem -Path $AttentionDir -Filter '*.json' -ErrorAction SilentlyContinue) {
      if (-not $nativeSids.ContainsKey($mf.BaseName)) { Remove-Item $mf.FullName -ErrorAction SilentlyContinue }
    }
  }

  # Sort: busy first, then alive, then most recently updated
  $rows = @($rows | Sort-Object @{e={ -([int]$_.busy) }}, @{e={ -([int]$_.alive) }}, @{e={ -$_.upd }})

  # Overall Claude state drives the status GIF: needs_input > running > idle.
  # A dead-process ('stale') session counts as not-active and is ignored here.
  $st = 'idle'
  foreach ($r in $rows) {
    if (-not $r.alive) { continue }
    if ($r.color -eq 'needs_input') { $st = 'needs_input'; break }
    if ($r.color -eq 'busy')        { $st = 'running' }
  }
  $script:OverallState = $st

  # Reconcile the live list against $rows without clearing it. Reuse each session's
  # existing Border (updating its content in place), create one only for new sessions,
  # and move/insert it to the sorted position. Rows that stay put are never removed
  # from the visual tree, so the row under the cursor doesn't flicker on refresh.
  $seen = @{}
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    $sid = $r.sessionId
    $e = $script:RowMap[$sid]
    if (-not $e) { $e = New-Row; $script:RowMap[$sid] = $e }
    Set-RowData $e $r
    $seen[$sid] = $true

    # Place this row at index $i if it isn't already there.
    $cur = if ($i -lt $List.Items.Count) { $List.Items[$i] } else { $null }
    if (-not [object]::ReferenceEquals($cur, $e.Border)) {
      $at = $List.Items.IndexOf($e.Border)
      if ($at -ge 0) { $List.Items.RemoveAt($at) }
      if ($i -le $List.Items.Count) { $List.Items.Insert($i, $e.Border) }
      else { [void]$List.Items.Add($e.Border) }
    }
  }

  # Drop rows for sessions that disappeared.
  $stale = @($script:RowMap.Keys | Where-Object { -not $seen.ContainsKey($_) })
  foreach ($sid in $stale) {
    [void]$List.Items.Remove($script:RowMap[$sid].Border)
    $script:RowMap.Remove($sid)
  }

  $aliveCount = ($rows | Where-Object { $_.alive }).Count
  $busyCount  = ($rows | Where-Object { $_.busy -and $_.alive }).Count
  $grandTotal = 0L; foreach ($r in $rows) { $grandTotal += [long]$r.total }
  $CountText.Text = "$aliveCount active" +
    $(if ($busyCount)  { " $sep $busyCount busy" } else { '' }) +
    $(if ($grandTotal) { " $sep ~$(Format-Tokens $grandTotal) tok" } else { '' })
}

# ---------------------------------------------------------------------------
# Status GIF subsystem: a separate borderless/transparent/topmost/no-activate
# floating window that shows a different animated GIF per overall Claude state.
# ---------------------------------------------------------------------------
$script:OverallState   = 'idle'
$script:GifShownPath   = ''      # path currently DISPLAYED (dedup; stays put while a load is in flight)
$script:GifCache       = @{}     # path -> @{ frames; delays }  (decoded packs; UI thread only)
$script:GifActive      = $null   # @{ frames; delays; idx } currently animating
$script:gifHwnd        = [IntPtr]::Zero
$script:gifPinned      = $false
# Async loading: a background runspace downloads GIF bytes (the slow part, ~seconds for
# large remote GIFs) OFF the UI thread; the UI thread decodes the bytes (fast, ~150ms)
# when they arrive. The overlay never freezes on a download.
$script:GifBytes  = [hashtable]::Synchronized(@{})   # path -> byte[] OR 'FAILED'  (bg writes, UI reads)
$script:GifQueue  = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:GifQueued = @{}           # paths already enqueued this lifetime (UI thread only)
# Transient-failure retry state: a remote download that returns 'FAILED' (e.g. a network
# blip on tenor.com) is retried with capped backoff instead of hiding the GIF forever.
$script:GifFailN  = @{}           # remote path -> consecutive download-failure count (UI thread only)
$script:GifFailAt = @{}           # remote path -> earliest next retry time (UI thread only)

[xml]$gifXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude GIF" Width="200" Height="200"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip"
        WindowStartupLocation="Manual" Left="60" Top="360" Visibility="Hidden">
  <!-- Near-transparent (not fully) so the surface still hit-tests for dragging. -->
  <Grid x:Name="GifRoot" Background="#01000000">
    <Image x:Name="GifImage" Stretch="Uniform"/>
  </Grid>
</Window>
"@
$gifReader = New-Object System.Xml.XmlNodeReader $gifXaml
$script:gifWindow = [Windows.Markup.XamlReader]::Load($gifReader)
$script:GifImage  = $script:gifWindow.FindName('GifImage')
$gifRoot          = $script:gifWindow.FindName('GifRoot')

# Apply persisted geometry.
$script:gifWindow.Left   = $script:Gif.win.left
$script:gifWindow.Top    = $script:Gif.win.top
$script:gifWindow.Width  = [Math]::Max(60, $script:Gif.win.width)
$script:gifWindow.Height = [Math]::Max(60, $script:Gif.win.height)

# No-activate so clicking the GIF never steals foreground from the terminal.
$script:gifWindow.Add_SourceInitialized({
  $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:gifWindow).Handle
  if ($h -ne [IntPtr]::Zero) { [WinTools]::SetNoActivate($h); $script:gifHwnd = $h }
})
# Drag anywhere on the surface to move it; persist the new position.
$gifRoot.Add_MouseLeftButtonDown({
  $ol = $script:gifWindow.Left; $ot = $script:gifWindow.Top
  $script:gifWindow.DragMove()
  if ($script:gifWindow.Left -ne $ol -or $script:gifWindow.Top -ne $ot) {
    $script:Gif.win.left = $script:gifWindow.Left
    $script:Gif.win.top  = $script:gifWindow.Top
    Save-UISettings   # only when an actual move happened, not a bare click
  }
})
$script:gifWindow.Add_SizeChanged({
  $script:Gif.win.width  = $script:gifWindow.Width
  $script:Gif.win.height = $script:gifWindow.Height
  # Persist only on real user resizes; initial layout fires this while still hidden.
  if ($script:gifWindow.IsVisible) { Save-UISettings }
})

# Single shared animation timer: advances whichever decoded frame pack is active.
# One timer (instead of one-per-load) means a state switch only re-points it at the
# cached frames — no timer churn, no leaks, no re-decode.
$script:GifTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:GifTimer.Add_Tick({
  $a = $script:GifActive
  if (-not $a -or $a.frames.Count -le 1) { $script:GifTimer.Stop(); return }
  $a.idx = ($a.idx + 1) % $a.frames.Count
  $script:GifImage.Source = $a.frames[$a.idx]
  $script:GifTimer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(20, [int]$a.delays[$a.idx] * 10))
})

# Decode an already-fetched GIF stream into reusable frozen frames by compositing each
# differenced frame over the accumulated canvas (RenderTargetBitmap). Runs on the UI
# thread; ~1ms/frame (~900ms for 300 frames, one-time, then cached). Returns
# @{ frames; delays } or $null. Does NO network I/O (that's the background downloader).
function ConvertTo-GifPack($stream) {
  try {
    $decoder = New-Object System.Windows.Media.Imaging.GifBitmapDecoder(
      $stream,
      [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
      [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $count = $decoder.Frames.Count
    if ($count -le 0) { return $null }
    $fw = $decoder.Frames[0].PixelWidth
    $fh = $decoder.Frames[0].PixelHeight
    if ($fw -le 0 -or $fh -le 0) { return $null }

    $frames = New-Object System.Collections.ArrayList
    $delays = New-Object System.Collections.ArrayList
    $prev = $null
    for ($i = 0; $i -lt $count; $i++) {
      $fr = $decoder.Frames[$i]
      $left = 0; $top = 0; $delay = 10
      try {
        $md = [System.Windows.Media.Imaging.BitmapMetadata]$fr.Metadata
        try { $left  = [int]$md.GetQuery('/imgdesc/Left') }  catch {}
        try { $top   = [int]$md.GetQuery('/imgdesc/Top') }   catch {}
        try { $d = $md.GetQuery('/grctlext/Delay'); if ($d) { $delay = [int]$d } } catch {}
      } catch {}
      if ($delay -le 0) { $delay = 10 }   # delay is in centiseconds (1/100s)

      # EVERY frame must be composited over the accumulated canvas. GIF frames are
      # differenced and use disposal method 1 ("do not dispose"): each frame is drawn
      # OVER the previous one and is mostly transparent (only ~20% changed pixels). Using
      # a frame raw -- even a full-canvas one -- shows just those changed pixels as holes
      # over transparency and looks broken. Compositing each frame over the prior result
      # is correct (verified: 100% opaque content per frame) and costs ~1ms/frame.
      $dv = New-Object System.Windows.Media.DrawingVisual
      $dc = $dv.RenderOpen()
      if ($prev) { $dc.DrawImage($prev, (New-Object System.Windows.Rect(0, 0, $fw, $fh))) }
      $dc.DrawImage($fr, (New-Object System.Windows.Rect($left, $top, $fr.PixelWidth, $fr.PixelHeight)))
      $dc.Close()
      $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
        $fw, $fh, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
      $rtb.Render($dv)
      $rtb.Freeze()
      [void]$frames.Add($rtb)
      $prev = $rtb
      [void]$delays.Add($delay)
    }
    return [pscustomobject]@{ frames = $frames; delays = $delays }
  } catch { return $null }
}

# Decode a GIF already present on disk (a file path or file:// URL). Local files are
# read directly on the UI thread (no network), so no async download is needed.
function Get-LocalGifPack($path) {
  $local = $path -replace '^file:///?', ''
  if (-not (Test-Path -LiteralPath $local)) { return $null }
  $fs = $null
  try {
    $fs = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $local).ProviderPath)
    return ConvertTo-GifPack $fs
  } catch { return $null } finally { if ($fs) { $fs.Dispose() } }
}

# Point the shared timer at a decoded pack and reveal the window.
function Show-GifPack($pack) {
  $script:GifTimer.Stop()
  $script:GifActive = [pscustomobject]@{ frames = $pack.frames; delays = $pack.delays; idx = 0 }
  $script:GifImage.Source = $pack.frames[0]
  if (-not $script:gifWindow.IsVisible) { $script:gifWindow.Show() }
  if ($pack.frames.Count -gt 1) {
    $script:GifTimer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(20, [int]$pack.delays[0] * 10))
    $script:GifTimer.Start()
  }
}

function Hide-Gif {
  $script:GifTimer.Stop(); $script:GifActive = $null
  $script:GifImage.Source = $null
  $script:gifWindow.Hide()
}

# Background downloader runspace: drains $GifQueue, fetching GIF bytes off the UI thread
# (pure HTTP I/O, no WPF) so the overlay never blocks on a slow download. Writes the
# resulting byte[] (or the string 'FAILED') into the synchronized $GifBytes map; the UI
# thread decodes it on its next poll.
$script:DlRunspace = [runspacefactory]::CreateRunspace()
$script:DlRunspace.Open()
$script:DlRunspace.SessionStateProxy.SetVariable('q', $script:GifQueue)
$script:DlRunspace.SessionStateProxy.SetVariable('bytesMap', $script:GifBytes)
$script:DlPs = [powershell]::Create()
$script:DlPs.Runspace = $script:DlRunspace
[void]$script:DlPs.AddScript({
  try {
    [System.Net.ServicePointManager]::SecurityProtocol =
      [System.Net.SecurityProtocolType]::Tls12 -bor
      [System.Net.SecurityProtocolType]::Tls11 -bor
      [System.Net.SecurityProtocolType]::Tls
  } catch {}
  while ($true) {
    $path = $null
    try { if ($q.Count -gt 0) { $path = $q.Dequeue() } } catch {}
    if (-not $path) { Start-Sleep -Milliseconds 120; continue }
    if ($bytesMap.ContainsKey($path)) { continue }
    try {
      $req = [System.Net.HttpWebRequest]::Create($path)
      $req.Timeout = 20000; $req.ReadWriteTimeout = 20000; $req.UserAgent = 'Mozilla/5.0'
      $resp = $req.GetResponse()
      $ms = New-Object System.IO.MemoryStream
      $resp.GetResponseStream().CopyTo($ms)
      $resp.Close()
      $bytesMap[$path] = $ms.ToArray()
    } catch { $bytesMap[$path] = 'FAILED' }
  }
})
$script:DlHandle = $script:DlPs.BeginInvoke()

# Fast poll so a freshly-downloaded GIF appears promptly (Update-Gif dedups to a cheap
# no-op when nothing has changed).
$gifPollTimer = New-Object System.Windows.Threading.DispatcherTimer
$gifPollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$gifPollTimer.Add_Tick({ Update-Gif })
$gifPollTimer.Start()

# Reconcile the GIF window with the current overall state. Cheap no-op when the
# target GIF path hasn't changed. -force reloads even if the path is unchanged
# (used after the settings dialog edits paths).
function Update-Gif([bool]$force = $false) {
  if (-not $script:gifWindow) { return }
  $want = if ($script:Gif.enabled) { [string]$script:Gif.paths[$script:OverallState] } else { '' }
  if (-not $force -and $want -eq $script:GifShownPath) { return }

  if ([string]::IsNullOrWhiteSpace($want)) { Hide-Gif; $script:GifShownPath = $want; return }

  # Already decoded -> show instantly.
  if ($script:GifCache.ContainsKey($want)) { Show-GifPack $script:GifCache[$want]; $script:GifShownPath = $want; return }

  # Local file -> decode now (no network, fast).
  if ($want -notmatch '^https?://') {
    $pack = Get-LocalGifPack $want
    if ($pack) { $script:GifCache[$want] = $pack; Show-GifPack $pack }
    else { Hide-Gif }
    $script:GifShownPath = $want
    return
  }

  # Remote -> have the downloaded bytes arrived (from the background runspace)?
  $b = $script:GifBytes[$want]
  if ($b -is [byte[]]) {
    # Success: clear any prior failure backoff for this path.
    if ($script:GifFailN.ContainsKey($want)) { $script:GifFailN.Remove($want); $script:GifFailAt.Remove($want) }
    $ms = New-Object System.IO.MemoryStream(, $b)
    $pack = ConvertTo-GifPack $ms       # decode on UI thread (fast)
    if ($pack) { $script:GifCache[$want] = $pack; Show-GifPack $pack }
    else { Hide-Gif }                   # bytes weren't a valid GIF
    $script:GifShownPath = $want
    return
  }
  if ($b -eq 'FAILED') {
    # Transient download failure: retry with capped backoff instead of giving up
    # permanently. Leaves any currently-shown GIF on screen while we wait, and self-heals
    # the moment the network recovers (no need for the overall state to change first).
    $now = [DateTime]::UtcNow
    $due = $script:GifFailAt[$want]
    if (-not $due) {
      $n = [int]$script:GifFailN[$want] + 1
      $script:GifFailN[$want]  = $n
      $script:GifFailAt[$want] = $now.AddMilliseconds([Math]::Min(60000, $n * 5000))  # 5s,10s,...,cap 60s
      return
    }
    if ($now -lt $due) { return }       # still cooling down
    # Backoff elapsed: drop the FAILED marker + queued flag so the next poll re-enqueues.
    $script:GifFailAt.Remove($want)
    [void]$script:GifBytes.Remove($want)
    $script:GifQueued.Remove($want)
    return
  }

  # Bytes not here yet: enqueue the download once and LEAVE the current GIF on screen
  # (no freeze, no flicker). Do NOT advance GifShownPath -> the next poll re-checks and
  # shows it the instant the bytes arrive.
  if (-not $script:GifQueued.ContainsKey($want)) { $script:GifQueued[$want] = $true; $script:GifQueue.Enqueue($want) }
}

# Lightweight settings dialog: per-state GIF paths + an enable toggle.
function Show-GifSettings {
  [xml]$sx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Status GIFs" Width="380" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen">
  <Border CornerRadius="10" Background="#F2161616" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="14">
    <StackPanel>
      <TextBlock Text="Status GIF paths" Foreground="#FFE6A23C" FontFamily="Segoe UI Semibold" FontSize="13" Margin="0,0,0,10"/>
      <CheckBox x:Name="EnabledChk" Content="Show status GIF" Foreground="#FFFFFFFF" Margin="0,0,0,10"/>
      <TextBlock Text="Running (busy)" Foreground="#80FFFFFF" FontFamily="Segoe UI" FontSize="11"/>
      <TextBox x:Name="RunBox" Margin="0,2,0,8"/>
      <TextBlock Text="Needs input" Foreground="#80FFFFFF" FontFamily="Segoe UI" FontSize="11"/>
      <TextBox x:Name="NeedBox" Margin="0,2,0,8"/>
      <TextBlock Text="Idle" Foreground="#80FFFFFF" FontFamily="Segoe UI" FontSize="11"/>
      <TextBox x:Name="IdleBox" Margin="0,2,0,12"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="ResetBtn" Content="Reset" Width="70" Margin="0,0,8,0"/>
        <Button x:Name="CancelBtn" Content="Cancel" Width="70" Margin="0,0,8,0"/>
        <Button x:Name="SaveBtn" Content="Save" Width="70"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
  $r = New-Object System.Xml.XmlNodeReader $sx
  $w = [Windows.Markup.XamlReader]::Load($r)
  $en = $w.FindName('EnabledChk')
  $rb = $w.FindName('RunBox'); $nb = $w.FindName('NeedBox'); $ib = $w.FindName('IdleBox')
  $en.IsChecked = $script:Gif.enabled
  $rb.Text = $script:Gif.paths.running
  $nb.Text = $script:Gif.paths.needs_input
  $ib.Text = $script:Gif.paths.idle
  # NOTE: do NOT use .GetNewClosure() on these handlers. GetNewClosure wraps the block
  # in a new module where $script: resolves to that module (so $script:Gif is $null and
  # the handler throws). The dialog is modal, so these plain scriptblocks keep access to
  # the function's local controls AND the real $script:Gif scope.
  $w.FindName('ResetBtn').Add_Click({ $rb.Text = ''; $nb.Text = ''; $ib.Text = '' })
  $w.FindName('CancelBtn').Add_Click({ $w.Close() })
  $w.FindName('SaveBtn').Add_Click({
    $script:Gif.enabled           = [bool]$en.IsChecked
    $script:Gif.paths.running     = $rb.Text.Trim()
    $script:Gif.paths.needs_input = $nb.Text.Trim()
    $script:Gif.paths.idle        = $ib.Text.Trim()
    Save-UISettings
    # Paths may have changed -> drop stale decodes + downloaded bytes so new paths reload.
    $script:GifCache.Clear(); $script:GifBytes.Clear(); $script:GifQueued.Clear()
    $script:GifFailN.Clear(); $script:GifFailAt.Clear()
    $script:GifShownPath = ''
    Update-Gif $true
    $w.Close()
  })
  # The overlay is a no-activate window, so a modal opened from it gets MOUSE clicks
  # but not KEYBOARD focus (typed text would go to the terminal). Force this dialog to
  # the foreground using the same AttachThreadInput trick the overlay uses elsewhere,
  # then drop the caret into the first field so typing works immediately.
  $w.Add_Loaded({
    try {
      $hh = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
      if ($hh -ne [IntPtr]::Zero) { [WinTools]::Focus($hh) }
    } catch {}
    $rb.Focus() | Out-Null
    [System.Windows.Input.Keyboard]::Focus($rb) | Out-Null
  })
  [void]$w.ShowDialog()
}

$GifBtn.Add_Click({ Show-GifSettings })

# Keep the GIF window on every virtual desktop: pin it (Windows-side) once visible;
# if pinning is unavailable, fall back to following the active desktop.
$gifDesktopTimer = New-Object System.Windows.Threading.DispatcherTimer
$gifDesktopTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$gifDesktopTimer.Add_Tick({
  if (-not $script:gifWindow.IsVisible -or $script:gifHwnd -eq [IntPtr]::Zero) { return }
  if (-not $script:gifPinned) { $script:gifPinned = [Pinner]::Pin($script:gifHwnd) }
  if (-not $script:gifPinned) { [VD]::Follow($script:gifHwnd) }
})
$gifDesktopTimer.Start()

# Initial render + refresh timer
Update-List
Update-Gif   # lazy-loads the current state's GIF; cached + instant on later switches
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Update-List; Update-Gif })
$timer.Start()

# Always-on-top + show-on-all-desktops, toggled by the header pin button. Primary: ask
# Windows to pin the window (Windows-side, no polling). Fallback: if pinning isn't
# available, a light timer keeps the overlay on the active desktop so it follows you.
$script:overlayHwnd = [IntPtr]::Zero
$script:pinned = $false

$followTimer = New-Object System.Windows.Threading.DispatcherTimer
$followTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$followTimer.Add_Tick({
  if ($script:overlayHwnd -ne [IntPtr]::Zero) { [VD]::Follow($script:overlayHwnd) }
})

# Apply (and persist) the pin state. ON = always-on-top + pinned/followed across every
# virtual desktop; OFF = a normal window that stays on its current desktop.
function Set-Pinned([bool]$on) {
  $script:UI.pinned = $on
  $Window.Topmost = $on
  $h = $script:overlayHwnd
  if ($on) {
    if ($h -ne [IntPtr]::Zero) { $script:pinned = [Pinner]::Pin($h) }
    if ($script:pinned) { $followTimer.Stop() } else { $followTimer.Start() }
    $PinBtn.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FFE6A23C')  # accent = pinned
    $PinBtn.ToolTip = 'Pinned: on top + all desktops (click to unpin)'
  } else {
    $followTimer.Stop()
    if ($h -ne [IntPtr]::Zero) { [void][Pinner]::Unpin($h) }
    $script:pinned = $false
    $PinBtn.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#66FFFFFF')  # dim = unpinned
    $PinBtn.ToolTip = 'Unpinned (click to pin on top + all desktops)'
  }
  Save-UISettings
}
$PinBtn.Add_Click({ Set-Pinned (-not $script:UI.pinned) })

# One-shot, ~600ms after show (the shell has registered the window as a view by then):
# apply the persisted pin state — pins, or leaves it unpinned.
$pinTimer = New-Object System.Windows.Threading.DispatcherTimer
$pinTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$pinTimer.Add_Tick({
  $pinTimer.Stop()
  $script:overlayHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
  Set-Pinned $script:UI.pinned
})
$pinTimer.Start()

$Window.Add_Closed({
  $timer.Stop(); $followTimer.Stop(); $pinTimer.Stop(); $gifDesktopTimer.Stop()
  if ($gifPollTimer) { $gifPollTimer.Stop() }
  if ($script:GifTimer) { $script:GifTimer.Stop() }
  $script:GifActive = $null
  if ($script:GifCache) { $script:GifCache.Clear() }
  # Stop the background downloader runspace so it doesn't outlive the window.
  try { if ($script:DlPs) { $script:DlPs.Stop(); $script:DlPs.Dispose() } } catch {}
  try { if ($script:DlRunspace) { $script:DlRunspace.Close(); $script:DlRunspace.Dispose() } } catch {}
  try {
    if ($script:gifWindow) {
      $script:Gif.win.width  = $script:gifWindow.Width
      $script:Gif.win.height = $script:gifWindow.Height
      Save-UISettings
      $script:gifWindow.Close()
    }
  } catch {}
})
[void]$Window.ShowDialog()
