# Claude Sessions Overlay
# A frameless, always-on-top WPF overlay that shows every running Claude Code
# session globally by reading ~/.claude/sessions/<pid>.json files.

# Single-instance guard (last-one-wins): if a previous overlay is running, kill
# it so this new instance takes over. We track the live overlay via a PID file.
$script:OverlayPidFile = Join-Path $env:TEMP 'ClaudeSessionsOverlay.pid'
$script:OverlayHostName = (Get-Process -Id $PID).ProcessName   # powershell / pwsh
if (Test-Path $script:OverlayPidFile) {
  $oldPid = Get-Content $script:OverlayPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($oldPid -match '^\d+$' -and [int]$oldPid -ne $PID) {
    $old = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
    # Only kill if the PID is still the same kind of host process (guards against
    # the OS recycling that PID for an unrelated process).
    if ($old -and $old.ProcessName -eq $script:OverlayHostName) {
      try { $old.Kill(); $old.WaitForExit(5000) } catch {}
    }
  }
}
Set-Content -Path $script:OverlayPidFile -Value $PID

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
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
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
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

  static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010, SWP_NOOWNERZORDER = 0x0200;

  // Force the window back to the top of the z-order without activating it. WPF's
  // Topmost=true is silently dropped when another app (e.g. a terminal) claims the top
  // slot; re-asserting HWND_TOPMOST on a timer keeps the overlay reliably on top.
  public static void ReassertTopmost(IntPtr h) {
    if (h == IntPtr.Zero) return;
    SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  }

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

  // Toggle WS_EX_NOACTIVATE so an inline input box can receive keyboard focus, then restore.
  public static void SetActivatable(IntPtr h, bool activatable) {
    int ex = GetWindowLong(h, -20);                                   // GWL_EXSTYLE
    int want = activatable ? (ex & ~0x08000000) : (ex | 0x08000000);  // WS_EX_NOACTIVATE
    if (want != ex) SetWindowLong(h, -20, want);
  }

  // Activate the overlay itself (after SetActivatable(true)) so its TextBox gets keystrokes.
  // Mirrors Focus(): zero the foreground lock and attach to the current foreground thread,
  // otherwise Windows refuses to let this (normally no-activate) window take foreground while
  // the terminal owns it, and keyboard focus never lands on the box.
  public static void ActivateSelf(IntPtr h) {
    if (h == IntPtr.Zero) return;
    uint oldTimeout = 0;
    SystemParametersInfo(SPI_GETFOREGROUNDLOCKTIMEOUT, 0, ref oldTimeout, 0);
    SystemParametersInfo(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, IntPtr.Zero, SPIF_SENDCHANGE);
    IntPtr fg = GetForegroundWindow();
    uint fgPid; uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
    uint cur = GetCurrentThreadId();
    bool attached = (fgThread != cur) && AttachThreadInput(cur, fgThread, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    SetFocus(h);   // give the HWND Win32 keyboard focus so WPF has focus to route to the box
    if (attached) AttachThreadInput(cur, fgThread, false);
    SystemParametersInfo(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, (IntPtr)(long)oldTimeout, SPIF_SENDCHANGE);
  }

  // --- Synthesised keystrokes (SendInput) for typing a prompt into the focused terminal. ---
  // Two trailing int pads make sizeof(INPUT) match the real Win32 union (40 on x64, 28 on
  // x86); SendInput only reads type + ki, which sit at the correct offsets either way.
  [StructLayout(LayoutKind.Sequential)]
  struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)]
  struct INPUT { public uint type; public KEYBDINPUT ki; public int padA; public int padB; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int cb);
  const uint INPUT_KEYBOARD = 1, KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;

  static INPUT UniInput(char c, bool up) {
    return new INPUT { type = INPUT_KEYBOARD, ki = new KEYBDINPUT {
      wVk = 0, wScan = c, dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0), time = 0, dwExtraInfo = IntPtr.Zero } };
  }
  static INPUT VkInput(ushort vk, bool up) {
    return new INPUT { type = INPUT_KEYBOARD, ki = new KEYBDINPUT {
      wVk = vk, wScan = 0, dwFlags = (up ? KEYEVENTF_KEYUP : 0), time = 0, dwExtraInfo = IntPtr.Zero } };
  }

  // Type a unicode string into whatever window currently has keyboard focus. Unicode scan
  // codes carry every character (incl. punctuation/emoji) verbatim — no SendKeys escaping.
  public static void SendText(string s) {
    if (string.IsNullOrEmpty(s)) return;
    var list = new List<INPUT>();
    foreach (char c in s) { list.Add(UniInput(c, false)); list.Add(UniInput(c, true)); }
    var arr = list.ToArray();
    SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
  }

  // Press Enter (submit the prompt).
  public static void SendEnter() {
    var arr = new INPUT[] { VkInput(0x0D, false), VkInput(0x0D, true) };
    SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
  }

  // Ctrl+V — paste the clipboard into the focused terminal. Used for multi-line prompts:
  // the terminal's bracketed-paste keeps embedded newlines as input instead of submitting,
  // so a single SendEnter afterwards submits the whole block (matching a human paste).
  public static void SendCtrlV() {
    var arr = new INPUT[] { VkInput(0x11, false), VkInput(0x56, false), VkInput(0x56, true), VkInput(0x11, true) };
    SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));   // 0x11=Ctrl, 0x56=V
  }
}
"@

# Click-through toggle. True cross-application click-through requires the
# WS_EX_TRANSPARENT extended style (HTTRANSPARENT only passes to same-thread windows,
# not to other apps). But WS_EX_TRANSPARENT makes the WHOLE window click-through,
# including the toggle button -- so a fast timer keeps it on everywhere EXCEPT while
# the cursor is over the button, leaving that one spot clickable to restore.
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class ClickThrough {
  public static bool Enabled = false;
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  const int GWL_EXSTYLE = -20;
  const int WS_EX_TRANSPARENT = 0x20;

  // Add or remove WS_EX_TRANSPARENT (preserving WS_EX_LAYERED / WS_EX_NOACTIVATE).
  public static void SetPassThrough(IntPtr h, bool on) {
    int ex = GetWindowLong(h, GWL_EXSTYLE);
    int want = on ? (ex | WS_EX_TRANSPARENT) : (ex & ~WS_EX_TRANSPARENT);
    if (want != ex) SetWindowLong(h, GWL_EXSTYLE, want);
  }

  public static POINT GetCursor() { POINT p; GetCursorPos(out p); return p; }
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

# ===========================================================================
# SessionState — typed model for ONE Claude Code session row.
#
# Single source of truth for both the FACTS of a session (read from
# ~/.claude/sessions/<pid>.json) and how it is PRESENTED (every string the row
# renders). Update-List builds one [SessionState] per session instead of a loose
# pscustomobject, so the row pipeline is: construct -> enrich -> render.
#
# PowerShell-class scope note: class methods cannot see script-scoped functions
# or variables. So the cache-backed enricher (transcript activity) runs in script
# scope and pushes its result in via the property setter below; everything that is
# PURE (formatting, tinting, lifecycle classification) lives here as
# instance/static members.
# ===========================================================================
class SessionState {
  static [char] $Sep   = [char]0x00B7   # middle dot separator (char code => encoding-safe)

  # --- Raw session facts ---
  [int]    $Pid
  [string] $Cwd
  [string] $SessionId
  [string] $Status        # native status, only ever 'busy' | 'idle'
  [long]   $UpdatedAt
  [string] $Version

  # --- Derived lifecycle state ---
  [bool]   $IsAlive
  [bool]   $IsBusy
  [string] $Color         # row-tint key: 'busy' | 'waiting' | 'stale' | 'idle'
  [string] $StatusText

  # --- Transcript-derived (filled by Enrich) ---
  [string] $Activity = ''
  [string] $Prompt   = ''
  [string] $Model    = ''
  [long]   $ContextTokens = 0    # current context-window fill = last assistant turn's input+cache tokens

  # --- Subagent (child row) facts. A child is a Task/Agent spawn nested under its
  #     parent session; it has no pid/session file of its own, so these are filled by
  #     the child constructor below, not the JSON ctor. ---
  [bool]   $IsChild    = $false  # nested under a parent (indented, keyed by agentId)
  [bool]   $IsSubagent = $false  # display with subagent treatment (tint/label, non-messageable)
  [string] $AgentId   = ''      # unique per subagent → row identity for children
  [string] $AgentType = ''      # e.g. 't1k-debugger' (transcript attributionAgent)
  [string] $Task      = ''      # first line of the spawn prompt

  # --- Per-tick snapshot (relative-time string is recomputed each refresh) ---
  [string] $AgeText = ''

  # Construct from the parsed session JSON plus the liveness verdict (the alive
  # set is a script-scope lookup, so the caller resolves it and passes the bool).
  SessionState([object]$json, [bool]$isAlive) {
    $this.Pid       = [int]$json.pid
    $this.Cwd       = "$($json.cwd)"
    $this.SessionId = "$($json.sessionId)"
    $this.Status    = "$($json.status)"
    $this.UpdatedAt = [long]$json.updatedAt
    $this.Version   = "$($json.version)"
    $this.IsAlive   = $isAlive
    $this.IsBusy    = ($this.Status -eq 'busy')

    if (-not $isAlive) {
      $this.Color = 'stale'; $this.StatusText = 'ended'
    } else {
      $this.Color = $this.Status; $this.StatusText = $this.Status
    }

    # A native session file with no advancing heartbeat (updatedAt at the Unix epoch)
    # that is also NOT a normal interactive CLI session is a headless/background agent
    # process, not a real session. Render it top-level but with the subagent treatment.
    $kind = "$($json.kind)"; $entry = "$($json.entrypoint)"
    if ($this.UpdatedAt -le 0 -and ($kind -ne 'interactive' -or $entry -ne 'cli')) {
      $this.IsSubagent = $true
      $this.Color      = 'child'
      $this.StatusText = 'subagent'
    }
  }

  # Child (subagent) constructor. Subagents have no pid and no ~/.claude/sessions file;
  # they are discovered from the parent's transcript subagents/ dir (Get-LiveSubagents),
  # so the parent supplies cwd + sessionId and the agent file supplies the rest. A child
  # is only ever constructed while it is live, so it is always alive/busy.
  SessionState([string]$agentId, [string]$parentSid, [string]$cwd, [string]$agentType, [string]$task, [long]$updatedAt) {
    $this.IsChild    = $true
    $this.IsSubagent = $true
    $this.AgentId    = $agentId
    $this.SessionId  = $parentSid          # parent linkage (not the child's own id)
    $this.Cwd        = $cwd
    $this.AgentType  = if ($agentType) { $agentType } else { 'subagent' }
    $this.Task       = $task
    $this.UpdatedAt  = $updatedAt
    $this.IsAlive    = $true
    $this.IsBusy     = $true
    $this.Color      = 'child'
    $this.StatusText = 'subagent'
  }

  # Row identity: children key on their unique agentId, parents on their sessionId.
  # (Agent ids are dash-free hex, session ids are UUIDs — they never collide.)
  [string] RowKey() {
    if ($this.IsChild) { return $this.AgentId }
    return $this.SessionId
  }

  # Promote an alive, non-busy session to the waiting state. The attention-marker
  # file check is script-scope IO; the model only owns the resulting label.
  [void] MarkWaiting() {
    $this.Color = 'waiting'; $this.StatusText = 'needs input'
  }

  # Push transcript-derived fields in (computed by Get-SessionActivity).
  [void] Enrich([object]$activity) {
    if (-not $activity) { return }
    $this.Activity      = "$($activity.activity)"
    $this.Prompt        = "$($activity.prompt)"
    $this.Model         = "$($activity.model)"
    $this.ContextTokens = [long]$activity.context
  }

  # Override the activity line with the live hook signal (session-activity.cjs),
  # which carries the precise current tool + target. Wins over the transcript-derived
  # Activity because it is both fresher and more specific. Empty input is a no-op.
  [void] SetActivity([string]$a) {
    if ($a) { $this.Activity = $a }
  }

  # Override the prompt with the live hook signal (session-prompt.cjs), which captures
  # the exact prompt at submit time. Wins over the transcript-derived Prompt because it
  # is both verbatim and not subject to the tail-window loss. Empty input is a no-op.
  [void] SetPrompt([string]$p) {
    if ($p) { $this.Prompt = $p }
  }

  # Refresh the relative-age snapshot against the current clock (called per tick).
  [void] StampAge([long]$now) {
    # A zero/absent timestamp would otherwise read as ~20615d (age measured from the Unix
    # epoch). Show nothing instead — true for a session JSON caught mid-write and for the
    # epoch headless-agent files flagged as subagents above.
    if ($this.UpdatedAt -le 0) { $this.AgeText = ''; return }
    $this.AgeText = [SessionState]::FormatAge($now - $this.UpdatedAt)
  }

  # --- Display projections (consumed by Set-RowData) ---

  [string] Name() {
    if ($this.IsChild) { return $this.AgentType }
    if ([string]::IsNullOrWhiteSpace($this.Cwd)) { return 'unknown' }
    $leaf = [System.IO.Path]::GetFileName($this.Cwd.TrimEnd([char]'\', [char]'/'))
    if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf }
    return $this.Cwd
  }

  [string] Sub() {
    if ($this.IsChild) { if ($this.Task) { return $this.Task } return 'working' }
    if ($this.Activity) { return $this.Activity }
    return "$($this.StatusText) $([SessionState]::Sep) pid $($this.Pid)"
  }

  # Current context-window fill (e.g. "ctx 139K"); empty until a turn is recorded.
  [string] CtxText() {
    if ($this.ContextTokens -le 0) { return '' }
    return "ctx $([SessionState]::FormatCtx($this.ContextTokens))"
  }

  [string] MetaText() {
    $parts = @()
    $m = [SessionState]::FormatModel($this.Model)
    if ($m)            { $parts += $m }
    if ($this.Version) { $parts += "v$($this.Version)" }
    return ($parts -join " $([SessionState]::Sep) ")
  }

  [string] Tip() {
    if ($this.IsChild) {
      $tip = "subagent $([SessionState]::Sep) $($this.AgentType)"
      if ($this.Task) { $tip += "`n`n$($this.Task)" }
      return $tip
    }
    $tip = "pid $($this.Pid) $([SessionState]::Sep) v$($this.Version) $([SessionState]::Sep) $($this.StatusText)`n$($this.Cwd)"
    if ($this.Prompt)   { $tip += "`n`nprompt: $($this.Prompt)" }
    if ($this.Activity) { $tip += "`n`n$($this.Activity)" }
    return $tip
  }

  # --- Pure static formatters (folded in from the old script-level Format-* fns) ---

  static [string] FormatAge([long]$ms) {
    if ($ms -le 0) { return 'now' }
    $s = [int]($ms / 1000)
    if ($s -lt 60) { return "${s}s" }
    $m = [int]($s / 60)
    if ($m -lt 60) { return "${m}m" }
    $h = [int]($m / 60)
    if ($h -lt 24) { return "${h}h" }
    $d = [int]($h / 24)
    return "${d}d"
  }

  # Token count -> compact label: 139234 -> "139K"; 1200000 -> "1.2M".
  static [string] FormatCtx([long]$n) {
    if ($n -le 0)        { return '0' }
    if ($n -lt 1000)     { return "$n" }
    if ($n -lt 1000000)  { return "$([int][math]::Round($n / 1000.0))K" }
    return "$([math]::Round($n / 1000000.0, 1))M"
  }

  # "claude-opus-4-8" -> "opus 4.8"; "claude-haiku-4-5-20251001" -> "haiku 4.5".
  static [string] FormatModel([string]$m) {
    if (-not $m) { return '' }
    $x = $m -replace '^claude-', '' -replace '-\d{8}$', ''   # strip prefix + trailing date stamp
    $mt = [regex]::Match($x, '^([a-z]+)-(\d+)-(\d+)')
    if ($mt.Success) { return "$($mt.Groups[1].Value) $($mt.Groups[2].Value).$($mt.Groups[3].Value)" }
    return $x
  }

  # Status -> row background tint (base + hover shades). Replaces the old status dot.
  static [hashtable] Tint([string]$color) {
    switch ($color) {
      'busy'    { return @{ base = '#2E3FB950'; hover = '#4D3FB950' } }   # green  = running
      'waiting' { return @{ base = '#38D29922'; hover = '#57D29922' } }   # yellow = waiting for input
      'stale'   { return @{ base = '#33F85149'; hover = '#52F85149' } }   # red    = process ended
      'idle'    { return @{ base = '#386E7681'; hover = '#576E7681' } }   # gray   = idle
      'child'   { return @{ base = '#332D9A7D'; hover = '#502D9A7D' } }   # teal   = live subagent
    }
    return @{ base = '#386E7681'; hover = '#57D29922' }                   # default / unknown
  }
}

$SessionsDir = Join-Path $env:USERPROFILE '.claude\sessions'
# waiting markers written by scripts\session-attention.cjs (Notification hook).
# The native session JSON only ever carries busy/idle, so this sidecar is the sole
# source for the "Claude is waiting for the user" state.
$AttentionDir = Join-Path $env:USERPROFILE '.claude\session-attention'
# live activity written by scripts\session-activity.cjs (PreToolUse hook). Carries the
# precise "what right now" line ("Editing overlay.ps1", "Bash: git status") that the
# transcript tail-parse can't surface — only ever shown while the session is busy.
$StatusDir = Join-Path $env:USERPROFILE '.claude\session-status'
# last user prompt written by scripts\session-prompt.cjs (UserPromptSubmit hook). Captures
# the exact prompt at submit time, so the row shows it verbatim instead of the lossy
# transcript tail-parse. Persists across the session (overwritten on each new prompt).
$PromptDir = Join-Path $env:USERPROFILE '.claude\session-prompt'

# Persisted "links": claudePid -> terminal window handle, for sessions whose window
# title can't be auto-matched (right-click a row to link it to the current terminal).
# Keyed by Claude PID (not sessionId) so a link survives /clear, which mints a new
# sessionId but leaves the process -- and its terminal window -- unchanged.
$LinksFile = Join-Path $PSScriptRoot 'links.json'
$script:Links = @{}
# In-memory "last seen present" stamp (unix ms) per linked claudePid. A link is reaped
# once its Claude process has been absent from the alive set for longer than
# $StaleLinkMs, so links.json stays bounded instead of growing forever across sessions.
# (The grace window also absorbs a transient disappearance between ticks.)
$script:LinkSeen = @{}
$StaleLinkMs = 24 * 60 * 60 * 1000   # 1 day
if (Test-Path $LinksFile) {
  try {
    $loadNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    (Get-Content $LinksFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
      $script:Links[[int]$_.Name] = [int64]$_.Value     # keys normalized to int to match the alive-PID set
      $script:LinkSeen[[int]$_.Name] = $loadNow          # seed grace so disk links aren't reaped instantly
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
  <Window.Resources>
    <!-- Minimal dark vertical scrollbar: thin, rounded, and intentionally low-contrast. -->
    <Style x:Key="MinimalDarkScrollBar" TargetType="{x:Type ScrollBar}">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ScrollBar}">
            <Grid Background="Transparent" Width="6">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Opacity="0" IsHitTestVisible="False"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Background="#66000000" BorderThickness="0">
                    <Thumb.Template>
                      <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border Background="{TemplateBinding Background}" CornerRadius="3"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Opacity="0" IsHitTestVisible="False"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
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
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="&#x25CF; Claude Sessions" Foreground="#FFE6A23C"
                     FontFamily="Segoe UI Semibold" FontSize="12" VerticalAlignment="Center"
                     Margin="12,0,0,0"/>
          <Button Grid.Column="1" x:Name="OpacityBtn" Content="&#x25D1;" Width="30" Height="30" Margin="0,0,8,0"
                  Foreground="#99FFFFFF" Background="Transparent" BorderThickness="0"
                  FontSize="13" Cursor="Hand" ToolTip="Window opacity"/>
          <Popup Grid.Column="1" x:Name="OpacityPopup" PlacementTarget="{Binding ElementName=OpacityBtn}"
                 Placement="Bottom" StaysOpen="False" AllowsTransparency="True" VerticalOffset="2">
            <Border CornerRadius="8" Background="#F2161616" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="12,8">
              <Slider x:Name="OpacitySlider" Minimum="0.25" Maximum="1.0" Value="0.95"
                      Width="130" VerticalAlignment="Center"
                      ToolTip="Window opacity" IsMoveToPointEnabled="True"/>
            </Border>
          </Popup>
          <TextBlock Grid.Column="2" x:Name="CountText" Text="" Foreground="#80FFFFFF"
                     FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <Button Grid.Column="3" x:Name="GifBtn" Content="GIF" Width="34" Height="30"
                  Foreground="#99FFFFFF" Background="Transparent" BorderThickness="0"
                  FontSize="11" Cursor="Hand" ToolTip="Configure status GIFs"/>
          <Button Grid.Column="4" x:Name="SndBtn" Content="&#x1F509;" Width="30" Height="30"
                  Foreground="#99FFFFFF" Background="Transparent" BorderThickness="0"
                  FontSize="13" Cursor="Hand" ToolTip="Configure status sounds"/>
          <Button Grid.Column="5" x:Name="FitBtn" Content="&#x2922;3" Width="34" Height="30"
                  Foreground="#99FFFFFF" Background="Transparent" BorderThickness="0"
                  FontSize="11" Cursor="Hand" ToolTip="Auto-fit cap: max sessions the list auto-grows to fit"/>
          <Button Grid.Column="6" x:Name="ClickThruBtn" Content="&#x25CE;" Width="30" Height="30"
                  Foreground="#99FFFFFF" Background="Transparent" BorderThickness="0"
                  FontSize="14" Cursor="Hand" ToolTip="Click-through: OFF (clicks hit the overlay)"/>
          <Button Grid.Column="7" x:Name="CloseBtn" Content="&#x2715;" Width="30" Height="30"
                  Foreground="#99FFFFFF" Background="Transparent" BorderThickness="0"
                  FontSize="13" Cursor="Hand"/>
        </Grid>
        <!-- Session list: height is snap-resized in row units (2 sessions, 3 sessions, etc.). -->
        <ScrollViewer x:Name="ScrollHost" Margin="8,2,8,10"
                      VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled"
                      CanContentScroll="False"
                      PanningMode="VerticalOnly">
          <ScrollViewer.Resources>
            <Style TargetType="{x:Type ScrollBar}" BasedOn="{StaticResource MinimalDarkScrollBar}"/>
          </ScrollViewer.Resources>
          <ItemsControl x:Name="List" Margin="0"/>
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
      <!-- Bottom-edge handle for vertical resizing. It snaps the list height to whole rows. -->
      <Thumb x:Name="ResizeGripV" VerticalAlignment="Bottom" Height="7" Margin="8,0,14,2" Cursor="SizeNS">
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
$ScrollHost = $Window.FindName('ScrollHost')
$CloseBtn   = $Window.FindName('CloseBtn')
$ClickThruBtn = $Window.FindName('ClickThruBtn')
$CountText  = $Window.FindName('CountText')
$ResizeGrip = $Window.FindName('ResizeGrip')
$ResizeGripV = $Window.FindName('ResizeGripV')
$OpacitySlider = $Window.FindName('OpacitySlider')
$OpacityBtn = $Window.FindName('OpacityBtn')
$OpacityPopup = $Window.FindName('OpacityPopup')
$GifBtn     = $Window.FindName('GifBtn')
$SndBtn     = $Window.FindName('SndBtn')
$FitBtn     = $Window.FindName('FitBtn')

# Persisted UI settings (width + opacity).
$UISettingsFile = Join-Path $PSScriptRoot 'settings.json'
$script:UI = @{ width = 340.0; opacity = 0.95; visibleRows = 3; autoFitCap = 3 }

# Per-state GIF config. Each path is user-configured (a local file path, or a
# file:// / http(s) URL); an empty path means "no GIF for that state". The floating
# GIF window shows the GIF for the current overall Claude state, aggregated across all
# sessions with priority waiting > running > idle. Empty default = feature off.
$script:Gif = @{
  enabled = $true
  paths   = @{ running = ''; waiting = ''; idle = '' }
  win     = @{ left = 60.0; top = 360.0; width = 200.0; height = 200.0 }
}

# Per-state sound config. Each path is a user-configured local file (.wav/.mp3/...) or
# file:// / http(s) URL; an empty path means "no sound for that state". A sound fires
# ONCE on each transition into its state, PER SESSION (it's an event, not a looping
# display) — the audio analogue of the status GIF, but evaluated per individual session
# rather than on the aggregated overall state. Empty default = feature off.
# nag = per-state re-nag config: while a session stays in a given state, its sound is
# re-played every `interval` seconds, up to `max` times per entry (max = 0 means forever).
# Default: only `waiting` nags (preserving the prior waiting-only behavior); the others are
# armed-able but off by default.
$script:Snd = @{
  enabled = $true
  volume  = 0.8                       # 0.0-1.0, applied to every sound played
  paths   = @{ running = ''; waiting = ''; idle = '' }
  # Per-state enable: unchecking silences that one state without clearing its path.
  # Default on, so a configured path keeps playing as before.
  pathEnabled = @{ running = $true; waiting = $true; idle = $true }
  nag     = @{
    running = @{ enabled = $false; interval = 60; max = 0 }
    waiting = @{ enabled = $true;  interval = 60; max = 0 }
    idle    = @{ enabled = $false; interval = 60; max = 0 }
  }
}
$script:SndPlayer    = $null          # reused MediaPlayer (created lazily on UI thread)
# Per-session sound state: a sound fires on each INDIVIDUAL session's transition
# (running/waiting/idle), not on the aggregated overall state — so a second session going
# `waiting` chimes even while another already is. Two parallel maps keyed by sessionId:
# the current snapshot (rebuilt each tick by Update-List) and the last state each session's
# sound was reconciled against (advanced by Update-Sound). Ended sessions drop out.
$script:SndCurStates     = @{}        # sessionId -> 'running'|'waiting'|'idle' (alive only)
$script:SndSessionStates = @{}        # sessionId -> last sound-state fired/seen
# Per-session re-nag bookkeeping: while a session holds a nag-enabled state, its sound is
# replayed every `interval`s up to `max` times. sessionId -> @{ lastNag = <ms>; count }.
$script:SndNag = @{}
# Remote sounds can't be streamed reliably through MediaPlayer (hotlink/UA/TLS), so they
# are fetched to a temp file off the UI thread (same approach as the GIF downloader) and
# played from disk. These mirror the $Gif* download plumbing.
$script:SndFiles  = [hashtable]::Synchronized(@{})                     # url -> local temp path | 'FAILED'
$script:SndQueue  = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$script:SndQueued = @{}                # urls already enqueued (UI-thread only)
if (Test-Path $UISettingsFile) {
  try {
    $cfg = Get-Content $UISettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.width)   { $script:UI.width   = [double]$cfg.width }
    if ($cfg.opacity) { $script:UI.opacity = [double]$cfg.opacity }
    if ($cfg.visibleRows) { $script:UI.visibleRows = [int]$cfg.visibleRows }
    if ($null -ne $cfg.autoFitCap) { $script:UI.autoFitCap = [int]$cfg.autoFitCap }
    # GIF settings are additive: missing keys fall back to the defaults above.
    if ($null -ne $cfg.gifEnabled) { $script:Gif.enabled = [bool]$cfg.gifEnabled }
    if ($cfg.gifPaths) {
      foreach ($k in 'running','waiting','idle') {
        if ($cfg.gifPaths.$k) { $script:Gif.paths[$k] = [string]$cfg.gifPaths.$k }
      }
    }
    if ($cfg.gifWindow) {
      foreach ($k in 'left','top','width','height') {
        if ($null -ne $cfg.gifWindow.$k) { $script:Gif.win[$k] = [double]$cfg.gifWindow.$k }
      }
    }
    # Sound settings are additive: missing keys fall back to the defaults above.
    if ($null -ne $cfg.sndEnabled) { $script:Snd.enabled = [bool]$cfg.sndEnabled }
    if ($null -ne $cfg.sndVolume) { $script:Snd.volume = [Math]::Max(0.0, [Math]::Min(1.0, [double]$cfg.sndVolume)) }
    if ($cfg.sndPaths) {
      foreach ($k in 'running','waiting','idle') {
        if ($cfg.sndPaths.$k) { $script:Snd.paths[$k] = [string]$cfg.sndPaths.$k }
      }
    }
    if ($cfg.sndPathEnabled) {
      foreach ($k in 'running','waiting','idle') {
        if ($null -ne $cfg.sndPathEnabled.$k) { $script:Snd.pathEnabled[$k] = [bool]$cfg.sndPathEnabled.$k }
      }
    }
    if ($cfg.sndNag) {
      foreach ($k in 'running','waiting','idle') {
        if ($cfg.sndNag.$k) {
          if ($null -ne $cfg.sndNag.$k.enabled)  { $script:Snd.nag[$k].enabled  = [bool]$cfg.sndNag.$k.enabled }
          if ($null -ne $cfg.sndNag.$k.interval) { $script:Snd.nag[$k].interval = [Math]::Max(1, [int]$cfg.sndNag.$k.interval) }
          if ($null -ne $cfg.sndNag.$k.max)      { $script:Snd.nag[$k].max      = [Math]::Max(0, [int]$cfg.sndNag.$k.max) }
        }
      }
    }
  } catch {}
}
function Save-UISettings {
  try {
    [pscustomobject]@{
      width       = $Window.Width
      opacity     = $OpacitySlider.Value
      visibleRows = $script:UI.visibleRows
      autoFitCap  = $script:UI.autoFitCap
      gifEnabled  = $script:Gif.enabled
      gifPaths   = [pscustomobject]$script:Gif.paths
      gifWindow  = [pscustomobject]$script:Gif.win
      sndEnabled  = $script:Snd.enabled
      sndVolume   = $script:Snd.volume
      sndPaths    = [pscustomobject]$script:Snd.paths
      sndPathEnabled = [pscustomobject]$script:Snd.pathEnabled
      sndNag      = [pscustomobject]@{
        running = [pscustomobject]$script:Snd.nag.running
        waiting = [pscustomobject]$script:Snd.nag.waiting
        idle    = [pscustomobject]$script:Snd.nag.idle
      }
    } | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $UISettingsFile -Encoding UTF8
  } catch {}
}

# Apply saved width + opacity.
$Window.Width = [Math]::Max(240, [Math]::Min(1000, $script:UI.width))
$OpacitySlider.Value = [Math]::Max(0.25, [Math]::Min(1.0, $script:UI.opacity))
$Window.Opacity = $OpacitySlider.Value
$Window.Topmost = $true   # always pinned on top from first paint
$script:UI.visibleRows = [Math]::Max(1, [Math]::Min(12, [int]$script:UI.visibleRows))

# Auto-fit: when a new session appears, grow the list to show all sessions -- but
# only while the total stays at or below the cap (settings.json -> autoFitCap).
# Past the cap, the user-set (or scrollable) height is left alone.
# -1 means "not yet measured".
$script:UI.autoFitCap = [Math]::Max(1, [Math]::Min(12, [int]$script:UI.autoFitCap))
$script:LastSessionCount = -1

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

# Click-through toggle. While enabled, a fast timer keeps WS_EX_TRANSPARENT on (true
# cross-app pass-through) EXCEPT while the cursor is over the toggle button, so that one
# spot stays clickable to restore. Recomputing the button rect each tick keeps it correct
# as the window moves or the list grows.
$script:CtTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:CtTimer.Interval = [TimeSpan]::FromMilliseconds(25)
$script:CtTimer.Add_Tick({
  if (-not [ClickThrough]::Enabled -or -not $script:overlayHwnd) { return }
  try {
    $tl = $ClickThruBtn.PointToScreen([System.Windows.Point]::new(0,0))
    $br = $ClickThruBtn.PointToScreen([System.Windows.Point]::new($ClickThruBtn.ActualWidth, $ClickThruBtn.ActualHeight))
    $p  = [ClickThrough]::GetCursor()
    $overBtn = ($p.X -ge $tl.X -and $p.X -lt $br.X -and $p.Y -ge $tl.Y -and $p.Y -lt $br.Y)
    [ClickThrough]::SetPassThrough($script:overlayHwnd, (-not $overBtn))
  } catch {}
})
$ClickThruBtn.Add_Click({
  if ([ClickThrough]::Enabled) {
    [ClickThrough]::Enabled = $false
    $script:CtTimer.Stop()
    if ($script:overlayHwnd) { [ClickThrough]::SetPassThrough($script:overlayHwnd, $false) }  # restore interaction
    $ClickThruBtn.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#99FFFFFF')
    $ClickThruBtn.ToolTip = 'Click-through: OFF (clicks hit the overlay)'
  } else {
    [ClickThrough]::Enabled = $true
    $script:CtTimer.Start()
    $ClickThruBtn.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FFE6A23C')
    $ClickThruBtn.ToolTip = 'Click-through: ON (clicks pass through; click here to restore)'
  }
})

# Opacity slider -> window opacity.
$OpacitySlider.Add_ValueChanged({ $Window.Opacity = $_.NewValue })
$OpacitySlider.Add_PreviewMouseUp({ Save-UISettings })

# Opacity slider is hidden by default; the button drops it down. StaysOpen="False" on the
# popup auto-hides it on any click outside. Open-only here so the outside-click-then-button
# sequence (the button click counts as the outside click that closes it) doesn't fight.
$OpacityBtn.Add_Click({ $OpacityPopup.IsOpen = $true })

# Right-edge grip -> horizontal resize.
$ResizeGrip.Add_DragDelta({
  $w = $Window.Width + $_.HorizontalChange
  $Window.Width = [Math]::Max(240, [Math]::Min(1000, $w))
})
$ResizeGrip.Add_DragCompleted({ Save-UISettings })

function Get-RowOuterHeight($item) {
  if (-not $item) { return 66.0 }
  $h = if ($item.ActualHeight -gt 0) { [double]$item.ActualHeight } else { 66.0 }
  try { $h += [double]$item.Margin.Top + [double]$item.Margin.Bottom } catch {}
  return [Math]::Max(42.0, $h)
}

function Get-RowSlotHeight {
  $sum = 0.0; $count = 0
  foreach ($item in $List.Items) {
    if ($item -and $item.ActualHeight -gt 0) {
      $sum += (Get-RowOuterHeight $item)
      $count++
    }
  }
  if ($count -gt 0) { return [Math]::Max(42.0, $sum / $count) }
  return 66.0
}

function Get-ListHeightForRows([int]$rows) {
  $rows = [Math]::Max(1, $rows)
  if ($List.Items.Count -le 0) { return 48.0 }

  $take = [Math]::Min($rows, $List.Items.Count)
  $h = 0.0
  for ($i = 0; $i -lt $take; $i++) { $h += (Get-RowOuterHeight $List.Items[$i]) }
  return [Math]::Max(48.0, [Math]::Ceiling($h + 1.0))
}

function Get-SnappedRowsForHeight([double]$height) {
  $count = [int]$List.Items.Count
  if ($count -le 0) { return 1 }

  $maxRows = [Math]::Max(1, [Math]::Min(12, $count))
  $bestRows = 1
  $bestDiff = [double]::PositiveInfinity

  for ($rows = 1; $rows -le $maxRows; $rows++) {
    $snapHeight = [double](Get-ListHeightForRows $rows)
    $diff = [Math]::Abs($height - $snapHeight)
    if ($diff -lt $bestDiff) {
      $bestDiff = $diff
      $bestRows = $rows
    }
  }

  return $bestRows
}

function Apply-ListSnapHeight {
  if (-not $ScrollHost) { return }

  # During vertical dragging, do not snap on every refresh tick. Snapping while the
  # mouse is still moving causes WPF to resize the content under the cursor, which
  # can make DragDelta alternate and flicker. We only snap once on DragCompleted.
  if ($script:IsVResizing) { return }

  try { $ScrollHost.UpdateLayout(); $List.UpdateLayout() } catch {}

  $count = [int]$List.Items.Count
  if ($count -le 0) {
    $ScrollHost.Height = 48.0
    $ScrollHost.VerticalScrollBarVisibility = 'Disabled'
    return
  }

  $maxRows = [Math]::Max(1, [Math]::Min(12, $count))

  # Auto-extend on a newly added session: if the count grew and is still within the
  # cap, raise visibleRows to fit every row. Grow-only -- a manual shrink afterward,
  # or counts above the cap, are never overridden here.
  if ($script:LastSessionCount -ge 0 -and $count -gt $script:LastSessionCount -and $count -le [int]$script:UI.autoFitCap) {
    if ([int]$script:UI.visibleRows -lt $count) { $script:UI.visibleRows = $count }
  }
  $script:LastSessionCount = $count

  $script:UI.visibleRows = [Math]::Max(1, [Math]::Min($maxRows, [int]$script:UI.visibleRows))
  $ScrollHost.Height = Get-ListHeightForRows $script:UI.visibleRows
  $ScrollHost.VerticalScrollBarVisibility = if ($count -gt [int]$script:UI.visibleRows) { 'Auto' } else { 'Disabled' }
}

# Bottom-edge grip -> vertical resize. While dragging, preview the raw height;
# when the mouse is released, snap to the nearest whole session row.
$script:VResizeTargetHeight = 0.0
$script:IsVResizing = $false
$ResizeGripV.Add_DragStarted({
  $script:IsVResizing = $true
  try { $ScrollHost.UpdateLayout(); $List.UpdateLayout() } catch {}
  $script:VResizeTargetHeight = if ($ScrollHost.ActualHeight -gt 0) { [double]$ScrollHost.ActualHeight } else { Get-ListHeightForRows $script:UI.visibleRows }
})
$ResizeGripV.Add_DragDelta({
  if ($List.Items.Count -le 0) { return }

  $count = [int]$List.Items.Count
  $maxRows = [Math]::Max(1, [Math]::Min(12, $count))
  $minH = [double](Get-ListHeightForRows 1)
  $maxH = [double](Get-ListHeightForRows $maxRows)

  $script:VResizeTargetHeight += [double]$_.VerticalChange
  $script:VResizeTargetHeight = [Math]::Max($minH, [Math]::Min($maxH, $script:VResizeTargetHeight))

  # Preview freely during drag to avoid snap-layout feedback flicker.
  $ScrollHost.Height = [Math]::Ceiling($script:VResizeTargetHeight)
  $ScrollHost.VerticalScrollBarVisibility = if ($count -gt 1) { 'Auto' } else { 'Disabled' }
})
$ResizeGripV.Add_DragCompleted({
  if ($List.Items.Count -gt 0) {
    $h = if ($script:VResizeTargetHeight -gt 0) { [double]$script:VResizeTargetHeight } else { [double]$ScrollHost.ActualHeight }
    $script:UI.visibleRows = Get-SnappedRowsForHeight $h
  }
  $script:IsVResizing = $false
  Apply-ListSnapHeight
  Save-UISettings
})

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

# Read a session's transcript tail and summarise what it's currently doing, the most
# recent user prompt, and the model in use. Cached per session keyed on updatedAt, so
# idle sessions aren't re-parsed every tick.
# Returns @{ activity = <what it's doing>; prompt = <last user prompt>; model = <model id> }.
$script:ActivityCache = @{}
function Get-SessionActivity($cwd, $sessionId, $updatedAt) {
  $empty = @{ activity = ''; prompt = ''; model = ''; context = 0 }
  if (-not $sessionId -or -not $cwd) { return $empty }
  $cached = $script:ActivityCache[$sessionId]
  if ($cached -and $cached.upd -eq $updatedAt) { return $cached.val }

  $enc  = ($cwd -replace '[^A-Za-z0-9]', '-')
  $path = Join-Path $env:USERPROFILE ".claude\projects\$enc\$sessionId.jsonl"
  $val  = @{ activity = ''; prompt = ''; model = ''; context = 0 }
  if (Test-Path $path) {
    try {
      $lastUser = ''; $lastAsst = ''; $lastTool = ''; $lastModel = ''; $lastCtx = [long]0
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
          # Current context fill = the latest turn's total input (fresh + cache-write + cache-read).
          # Reading the LAST turn (not summing the transcript) is what makes this accurate.
          $u = $m.usage
          if ($u) {
            $ctx = [long]$u.input_tokens + [long]$u.cache_creation_input_tokens + [long]$u.cache_read_input_tokens
            if ($ctx -gt 0) { $lastCtx = $ctx }
          }
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
      $val = @{ activity = $act; prompt = $prompt; model = $lastModel; context = $lastCtx }
    } catch {}
  }
  $script:ActivityCache[$sessionId] = @{ upd = $updatedAt; val = $val }
  return $val
}

# Discover the LIVE subagents (Task/Agent spawns) of one parent session as child rows.
# Subagents have no pid and no ~/.claude/sessions file — they live as append-only
# transcripts under projects\<enc>\<parentSid>\subagents\agent-<id>.jsonl. A subagent is
# treated as live while its file was last written within $SubagentLiveMs (read-side only,
# no hook): a finished agent stops being written and ages out on its own. Agent type +
# spawn-prompt task are immutable per agent, so they're parsed once and cached by agentId.
$script:SubagentMetaCache = @{}   # agentId -> @{ type; task }
$SubagentLiveMs = 60000           # liveness window — wide enough to bridge a reasoning gap

function Get-LiveSubagents($cwd, $parentSid, $now) {
  $out = @()
  if (-not $cwd -or -not $parentSid) { return $out }
  $enc = ($cwd -replace '[^A-Za-z0-9]', '-')
  $dir = Join-Path $env:USERPROFILE ".claude\projects\$enc\$parentSid\subagents"
  if (-not (Test-Path $dir)) { return $out }

  foreach ($f in Get-ChildItem -Path $dir -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue) {
    $mtimeMs = [DateTimeOffset]::new($f.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
    if (($now - $mtimeMs) -gt $SubagentLiveMs) { continue }   # not live → skip

    $agentId = $f.BaseName -replace '^agent-', ''
    $meta = $script:SubagentMetaCache[$agentId]
    if (-not $meta -or -not $meta.type) {
      # (Re)read the head until both fields resolve. The task is on the first (user) line;
      # the agent type (attributionAgent) only appears once the first assistant turn lands.
      $type = if ($meta) { $meta.type } else { '' }
      $task = if ($meta) { $meta.task } else { '' }
      try {
        $head = @(Get-Content -Path $f.FullName -TotalCount 8 -Encoding UTF8 -ErrorAction Stop)
        if (-not $task -and $head.Count -gt 0) {
          try {
            $c0 = ($head[0] | ConvertFrom-Json).message.content
            $t0 = if ($c0 -is [string]) { $c0 } else { '' }
            if ($t0) {
              $t0 = (($t0 -split "`n")[0]).Trim()
              if ($t0.Length -gt 80) { $t0 = $t0.Substring(0, 80) }
              $task = $t0
            }
          } catch {}
        }
        if (-not $type) {
          foreach ($ln in $head) {
            $mt = [regex]::Match($ln, '"attributionAgent":"([^"]+)"')
            if ($mt.Success) { $type = $mt.Groups[1].Value; break }
          }
        }
      } catch {}
      $meta = @{ type = $type; task = $task }
      if ($type -and $task) { $script:SubagentMetaCache[$agentId] = $meta }   # cache once stable
    }

    $out += [SessionState]::new($agentId, $parentSid, $cwd, $meta.type, $meta.task, $mtimeMs)
  }
  # Most-recently-active subagent first within the parent group.
  return @($out | Sort-Object @{ e = { -$_.UpdatedAt } })
}

# Read the live activity marker (session-activity.cjs PreToolUse hook) for a session.
# Returns the precise current-work line ("Editing overlay.ps1") or '' when absent.
# Uncached: the file is tiny and changes every tool call, so a cache keyed on the
# native heartbeat would just go stale within a single busy turn.
function Get-SessionStatus($sessionId) {
  if (-not $sessionId) { return '' }
  $path = Join-Path $StatusDir "$sessionId.json"
  if (-not (Test-Path $path)) { return '' }
  try { return "$((Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json).activity)" } catch { return '' }
}

# Read the last-user-prompt marker (session-prompt.cjs UserPromptSubmit hook) for a session.
# Returns the verbatim prompt or '' when absent. Uncached: the file is tiny and only changes
# once per user turn, so a heartbeat-keyed cache would buy nothing.
function Get-SessionPrompt($sessionId) {
  if (-not $sessionId) { return '' }
  $path = Join-Path $PromptDir "$sessionId.json"
  if (-not (Test-Path $path)) { return '' }
  try { return "$((Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json).prompt)" } catch { return '' }
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
#   $cwd        disambiguates Windows Terminal windows/tabs by title.
#   $sessionPid looks up a user-created link (right-click) when the title can't be matched.
function Focus-Session($sessionPid, $cwd, $sessionId) {
  $sessionPid = [int]$sessionPid
  $folder = if ($cwd) { Split-Path $cwd -Leaf } else { '' }

  # Prefer an explicit user link if it still points to a live window.
  if ($script:Links.ContainsKey($sessionPid)) {
    $lh = [IntPtr]([int64]$script:Links[$sessionPid])
    if ((Test-LiveWindow $lh)) { [WinTools]::Focus($lh); return $true }
    $script:Links.Remove($sessionPid); Save-Links           # stale -> forget it
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

# --- Inline prompt input (shift-click a row) ------------------------------------------
# The overlay is a no-activate window, so its TextBox can't receive keystrokes until we
# temporarily clear WS_EX_NOACTIVATE and activate it. Show-PromptInput does that; the
# Enter/Escape/lost-focus handlers restore no-activate so clicking the overlay never
# steals foreground again. The box mirrors Claude's composer: a '>' chevron, placeholder,
# Enter to send / Shift+Enter for a newline (auto-grows), and Up/Down to recall history.

# Per-session prompt history (this run), keyed by Claude PID so it survives /clear.
$script:PromptHistory = @{}

function Add-PromptHistory($sessPid, $text) {
  $sessPid = [int]$sessPid
  if (-not $script:PromptHistory.ContainsKey($sessPid)) {
    $script:PromptHistory[$sessPid] = New-Object System.Collections.Generic.List[string]
  }
  $h = $script:PromptHistory[$sessPid]
  if ($h.Count -eq 0 -or $h[$h.Count - 1] -ne $text) { $h.Add($text) }  # de-dup consecutive
  while ($h.Count -gt 100) { $h.RemoveAt(0) }                            # bound growth
}

# The TextBox is reachable from a row border via the wrap stashed at outer.Children[1].
function Get-RowInput($border) {
  $wrap = $border.Child.Children[1]
  if ($wrap -and $wrap.Tag) { return $wrap.Tag.Box }
  return $null
}

function Update-Placeholder($box) {
  $ph = $box.Tag.Placeholder
  if ($ph) { $ph.Visibility = if ($box.Text.Length -eq 0) { 'Visible' } else { 'Collapsed' } }
}

# Up/Down recall, shell/Claude style. dir=-1 older, +1 newer. Returns $true if it consumed
# the key (so the caller suppresses the default caret move). In a multi-line draft the
# arrows move the caret normally and only recall at the very top / very bottom.
function Recall-History($box, [int]$dir) {
  $tag = $box.Tag
  $rb = $tag.RowBorder
  if (-not ($rb.Tag -and $rb.Tag.Pid)) { return $false }
  $hist = $script:PromptHistory[[int]$rb.Tag.Pid]
  if (-not $hist -or $hist.Count -eq 0) { return $false }
  $multi = $box.Text.Contains([char]10)
  if ($dir -lt 0) { if ($multi -and $box.CaretIndex -ne 0) { return $false } }
  else            { if ($multi -and $box.CaretIndex -ne $box.Text.Length) { return $false } }

  $idx = [int]$tag.HistIdx
  if ($dir -lt 0) {
    if ($idx -ge $hist.Count) { $tag.Draft = $box.Text }   # stash the live draft before leaving it
    if ($idx -le 0) { $tag.HistIdx = 0; return $true }      # already oldest; still consume the key
    $idx--
  } else {
    if ($idx -ge $hist.Count) { return $false }             # already on the draft; nothing newer
    $idx++
  }
  $tag.HistIdx = $idx
  $box.Text = if ($idx -ge $hist.Count) { $tag.Draft } else { $hist[$idx] }
  $box.CaretIndex = $box.Text.Length
  return $true
}

function Show-PromptInput($border) {
  $box = Get-RowInput $border
  if (-not $box) { return }
  $tag = $box.Tag
  $box.Text = ''
  $tag.Draft = ''
  # Start the history cursor past the newest entry (i.e. on the empty draft).
  $sp = if ($border.Tag -and $border.Tag.Pid) { [int]$border.Tag.Pid } else { 0 }
  $tag.HistIdx = if ($script:PromptHistory.ContainsKey($sp)) { $script:PromptHistory[$sp].Count } else { 0 }
  $tag.Wrap.Visibility = 'Visible'
  Update-Placeholder $box
  if ($script:overlayHwnd -ne [IntPtr]::Zero) {
    [WinTools]::SetActivatable($script:overlayHwnd, $true)
    [WinTools]::ActivateSelf($script:overlayHwnd)
  }
  # Realize the just-shown box now (Collapsed -> Visible needs a layout pass before
  # IsVisible flips true; focusing a not-yet-realized element is silently dropped).
  $box.UpdateLayout()
  [void]$box.Focus()
  [void][System.Windows.Input.Keyboard]::Focus($box)
  $box.CaretIndex = $box.Text.Length
  # Belt-and-suspenders: re-assert keyboard focus once the input queue drains, in case the
  # click that opened the box was still settling activation when the synchronous focus ran.
  $box.Dispatcher.BeginInvoke([action]{
    [void][System.Windows.Input.Keyboard]::Focus($box)
  }, [System.Windows.Threading.DispatcherPriority]::Input) | Out-Null
}

function Hide-PromptInput($box) {
  $tag = $box.Tag
  if ($tag.Wrap.Visibility -ne 'Collapsed') { $tag.Wrap.Visibility = 'Collapsed' }
  $box.Text = ''
  Update-Placeholder $box
  # Restore no-activate so the overlay stops stealing foreground on click.
  if ($script:overlayHwnd -ne [IntPtr]::Zero) {
    [WinTools]::SetActivatable($script:overlayHwnd, $false)
  }
}

# Focus the session's terminal, then deliver the prompt and submit it. Single-line goes in
# as Unicode keystrokes; multi-line is pasted (bracketed paste preserves newlines) with the
# clipboard saved and restored around the paste.
function Send-PromptToSession($targetPid, $cwd, $sessionId, $text) {
  if (-not (Focus-Session $targetPid $cwd $sessionId)) { return $false }
  Start-Sleep -Milliseconds 140   # let the terminal actually take foreground
  if ($text.Contains([char]10)) {
    $old = $null
    try { $old = [System.Windows.Clipboard]::GetText() } catch {}
    try { [System.Windows.Clipboard]::SetText($text) } catch {}
    Start-Sleep -Milliseconds 40
    [WinTools]::SendCtrlV()
    Start-Sleep -Milliseconds 90
    [WinTools]::SendEnter()
    if ($old) { try { [System.Windows.Clipboard]::SetText($old) } catch {} }   # restore clipboard
  } else {
    [WinTools]::SendText($text)
    Start-Sleep -Milliseconds 40
    [WinTools]::SendEnter()
  }
  return $true
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

  # Left-click focuses the session's terminal; Shift+left-click opens an inline prompt box;
  # right-click links it to the current terminal.
  $border.Add_MouseLeftButtonUp({
    # A click that lands inside the open input box must not bubble up and re-focus the
    # terminal (which would yank foreground away mid-typing).
    if ($_.OriginalSource -is [System.Windows.Controls.TextBox]) { return }
    $t = $this.Tag
    if (-not ($t -and $t.Pid)) { return }
    $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    # Shift-click opens the prompt composer — but only for real sessions. A subagent can't
    # be messaged, so shift-click on a child row just focuses the parent terminal instead.
    if ($shift -and -not $t.IsSubagent) { Show-PromptInput $this; return }
    $ok = Focus-Session $t.Pid $t.Cwd $t.SessionId
    if (-not $ok) { Show-RowFlash $this '#55F56C6C' }   # red: couldn't locate; right-click to link
  })

  # Right-click: link this session to whatever terminal is currently focused.
  # (The overlay is no-activate, so the foreground window is the terminal you came from.)
  # Keyed by Claude PID so the link survives /clear (which changes sessionId, not the PID).
  $border.Add_MouseRightButtonUp({
    $t = $this.Tag
    if ($t -and $t.IsSubagent) { return }   # subagent rows aren't linkable to a terminal
    if ($t -and $t.Pid) {
      $fg = [WinTools]::GetForegroundWindow()
      if ($fg -ne [IntPtr]::Zero -and $fg -ne $script:overlayHwnd) {
        $script:Links[[int]$t.Pid] = $fg.ToInt64()
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

  # Right column: current context fill (top) over relative age (bottom).
  $right = New-Object System.Windows.Controls.StackPanel
  $right.VerticalAlignment = 'Center'
  $right.Margin = '8,0,0,0'
  [Windows.Controls.Grid]::SetColumn($right, 1)

  # Current context-window fill (e.g. "ctx 139K"), dim blue. Collapsed until known.
  $ctx = New-Object System.Windows.Controls.TextBlock
  $ctx.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#997AC2FF')
  $ctx.FontFamily = 'Segoe UI'
  $ctx.FontSize = 10
  $ctx.HorizontalAlignment = 'Right'

  $age = New-Object System.Windows.Controls.TextBlock
  $age.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#66FFFFFF')
  $age.FontFamily = 'Segoe UI'
  $age.FontSize = 10
  $age.HorizontalAlignment = 'Right'

  $right.Children.Add($ctx) | Out-Null
  $right.Children.Add($age) | Out-Null

  $grid.Children.Add($stack) | Out-Null
  $grid.Children.Add($right) | Out-Null

  # Outer container so the inline prompt box can sit full-width below the row content.
  # (border.Child must be a single element; the grid alone can't host the extra box.)
  $outer = New-Object System.Windows.Controls.StackPanel
  $outer.Children.Add($grid) | Out-Null

  # --- Inline prompt composer (collapsed until shift-click) ---------------------------
  # Rounded wrap → '>' chevron + auto-growing TextBox with an overlaid placeholder, so it
  # reads like Claude's own input. Visibility is never touched by Set-RowData, so an open
  # box survives every refresh tick (rows are updated in place, not rebuilt).
  $wrap = New-Object System.Windows.Controls.Border
  $wrap.CornerRadius = '6'
  $wrap.Margin = '0,7,0,0'
  $wrap.Padding = '8,5,8,6'
  $wrap.Background = [Windows.Media.BrushConverter]::new().ConvertFrom('#40000000')
  $wrap.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFrom('#73E6A23C')
  $wrap.BorderThickness = '1'
  $wrap.Visibility = 'Collapsed'
  # Consume clicks inside the composer so they never bubble to the row's focus-terminal handler.
  $wrap.Add_MouseLeftButtonUp({ $_.Handled = $true })

  $wrapGrid = New-Object System.Windows.Controls.Grid
  $cc0 = New-Object System.Windows.Controls.ColumnDefinition; $cc0.Width = 'Auto'
  $cc1 = New-Object System.Windows.Controls.ColumnDefinition; $cc1.Width = '*'
  $wrapGrid.ColumnDefinitions.Add($cc0)
  $wrapGrid.ColumnDefinitions.Add($cc1)

  $chevron = New-Object System.Windows.Controls.TextBlock
  $chevron.Text = '>'
  $chevron.FontFamily = 'Consolas'
  $chevron.FontSize = 12
  $chevron.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#CCE6A23C')
  $chevron.VerticalAlignment = 'Top'
  $chevron.Margin = '0,1,7,0'
  $chevron.IsHitTestVisible = $false
  [Windows.Controls.Grid]::SetColumn($chevron, 0)

  # The text area: the editable box with a placeholder TextBlock layered over it.
  $boxHost = New-Object System.Windows.Controls.Grid
  [Windows.Controls.Grid]::SetColumn($boxHost, 1)

  $promptBox = New-Object System.Windows.Controls.TextBox
  $promptBox.FontFamily = 'Segoe UI'
  $promptBox.FontSize = 12
  $promptBox.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FFFFFFFF')
  $promptBox.Background = 'Transparent'
  $promptBox.BorderThickness = '0'
  $promptBox.Padding = '0'
  $promptBox.CaretBrush = [Windows.Media.BrushConverter]::new().ConvertFrom('#FFFFFFFF')
  $promptBox.AcceptsReturn = $true                 # Shift+Enter inserts a newline
  $promptBox.TextWrapping = 'Wrap'
  $promptBox.MaxHeight = 120                        # grows with content, then scrolls
  $promptBox.VerticalScrollBarVisibility = 'Auto'
  $promptBox.Cursor = 'IBeam'

  $placeholder = New-Object System.Windows.Controls.TextBlock
  $placeholder.Text = 'Send a message to this session...'
  $placeholder.FontFamily = 'Segoe UI'
  $placeholder.FontSize = 12
  $placeholder.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#80FFFFFF')
  $placeholder.VerticalAlignment = 'Top'
  $placeholder.IsHitTestVisible = $false

  $boxHost.Children.Add($promptBox) | Out-Null
  $boxHost.Children.Add($placeholder) | Out-Null

  $wrapGrid.Children.Add($chevron) | Out-Null
  $wrapGrid.Children.Add($boxHost) | Out-Null
  $wrap.Child = $wrapGrid

  # Stash cross-references for the handlers + Get-RowInput (border.Tag is reserved for
  # per-tick session data, so we hang these off the box/wrap Tags instead).
  $wrap.Tag = [pscustomobject]@{ Box = $promptBox }
  $promptBox.Tag = @{ RowBorder = $border; Wrap = $wrap; Placeholder = $placeholder; HistIdx = 0; Draft = '' }

  $promptBox.Add_TextChanged({ Update-Placeholder $this })

  # PreviewKeyDown (tunneling) so we intercept Enter/Esc/arrows before the TextBox does.
  # NB: capture the event args first — `switch` reassigns $_ to the switch item inside the
  # case blocks, so $_.Handled there would target the Key enum (and throw), not the event.
  $promptBox.Add_PreviewKeyDown({
    $ev = $_
    $box = $this
    $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    switch ($ev.Key) {
      'Return' {
        if ($shift) { return }              # Shift+Enter → newline (let the box handle it)
        $ev.Handled = $true
        $rb = $box.Tag.RowBorder
        $t = $rb.Tag
        $text = $box.Text
        if ($t -and $t.Pid -and $text) {
          Add-PromptHistory $t.Pid $text
          Hide-PromptInput $box             # collapse + restore no-activate BEFORE sending
          $sent = Send-PromptToSession $t.Pid $t.Cwd $t.SessionId $text
          Show-RowFlash $rb $(if ($sent) { '#5567C23A' } else { '#55F56C6C' })
        } else {
          Hide-PromptInput $box
        }
      }
      'Escape' { $ev.Handled = $true; Hide-PromptInput $box }
      'Up'     { if (Recall-History $box -1) { $ev.Handled = $true } }
      'Down'   { if (Recall-History $box  1) { $ev.Handled = $true } }
    }
  })
  # Clicking elsewhere (or focus otherwise leaving) cancels the box and restores no-activate.
  $promptBox.Add_LostKeyboardFocus({ Hide-PromptInput $this })

  $outer.Children.Add($wrap) | Out-Null
  $border.Child = $outer

  return @{
    Border = $border; RunName = $runName; RunPid = $runPid
    Prompt = $promptTb; Sub = $sub; Meta = $meta; Ctx = $ctx; Age = $age
  }
}

# Update an existing row's content in place from session data $r. Only writes a
# property when it actually changed, so unchanged rows incur no layout work and the
# row under the cursor is never disturbed. Background is intentionally untouched so
# the hover tint (set by MouseEnter/Leave) survives every refresh.
function Set-RowData($e, [SessionState]$s) {
  # Status -> row background tint (replaces the old dot). Carry base/hover on the Tag so
  # the MouseEnter/Leave handlers (and Show-RowFlash) restore the right shade.
  $tint = [SessionState]::Tint($s.Color)
  $e.Border.Tag = [pscustomobject]@{ Pid = $s.Pid; Cwd = $s.Cwd; SessionId = $s.SessionId; IsSubagent = $s.IsSubagent; BaseBg = $tint.base; HoverBg = $tint.hover }
  $tip = $s.Tip()
  if ($e.Border.ToolTip -ne $tip) { $e.Border.ToolTip = $tip }

  # Indent child (subagent) rows so they read as nested under their parent. Re-applied
  # only when the row's child/parent kind flips — which never happens for a given RowKey
  # (a child keys on agentId, a parent on sessionId) — so there is no per-tick churn.
  if ($e.IsChildRow -ne $s.IsChild) {
    $e.IsChildRow = $s.IsChild
    $e.Border.Margin = if ($s.IsChild) { '22,2,0,0' } else { '0,3,0,0' }
  }

  # Re-apply the background only when the tint or hover state actually changed, so an
  # unchanged row never churns its brush (keeps the in-place update blink-free).
  $bg = if ($e.Border.IsMouseOver) { $tint.hover } else { $tint.base }
  if ($e.LastBg -ne $bg) { $e.LastBg = $bg; $e.Border.Background = [Windows.Media.BrushConverter]::new().ConvertFrom($bg) }

  $name = $s.Name()
  if ($s.IsChild) { $name = "$([char]0x2514) $name" }   # '└ ' tree-branch prefix for nesting
  if ($e.RunName.Text -ne $name)        { $e.RunName.Text = $name }
  $pidTxt = if ($s.IsChild) { '' } else { "  $($s.Pid)" }   # a subagent has no pid of its own
  if ($e.RunPid.Text -ne $pidTxt)       { $e.RunPid.Text = $pidTxt }

  if ($s.Prompt) {
    if ($e.Prompt.Text -ne $s.Prompt)   { $e.Prompt.Text = $s.Prompt }
    if ($e.Prompt.Visibility -ne 'Visible') { $e.Prompt.Visibility = 'Visible' }
  } elseif ($e.Prompt.Visibility -ne 'Collapsed') {
    $e.Prompt.Visibility = 'Collapsed'
  }

  $sub = $s.Sub()
  if ($e.Sub.Text -ne $sub)             { $e.Sub.Text = $sub }

  $metaTxt = $s.MetaText()
  if ($metaTxt) {
    if ($e.Meta.Text -ne $metaTxt)      { $e.Meta.Text = $metaTxt }
    if ($e.Meta.Visibility -ne 'Visible') { $e.Meta.Visibility = 'Visible' }
  } elseif ($e.Meta.Visibility -ne 'Collapsed') {
    $e.Meta.Visibility = 'Collapsed'
  }

  $ctxTxt = $s.CtxText()
  if ($ctxTxt) {
    if ($e.Ctx.Text -ne $ctxTxt)        { $e.Ctx.Text = $ctxTxt }
    if ($e.Ctx.Visibility -ne 'Visible') { $e.Ctx.Visibility = 'Visible' }
  } elseif ($e.Ctx.Visibility -ne 'Collapsed') {
    $e.Ctx.Visibility = 'Collapsed'
  }

  if ($e.Age.Text -ne $s.AgeText)       { $e.Age.Text = $s.AgeText }
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
    $script:SndCurStates = @{}
    Apply-ListSnapHeight
    return
  }
  $alive = Get-AliveProcessIds
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $rows = @()
  $nativeSids = @{}   # sessionIds seen this tick, for reaping orphaned attention markers

  foreach ($file in Get-ChildItem -Path $SessionsDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    try { $json = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    if (-not $json.pid) { continue }

    # 1. Construct the model from the raw facts + liveness.
    $isAlive = $alive.ContainsKey([int]$json.pid)
    $session = [SessionState]::new($json, $isAlive)

    # 2. waiting-state refinement (script-scope IO the model can't do itself).
    # waiting is a refinement of the idle state. The native session file only ever
    # carries busy/idle; the Notification hook (scripts\session-attention.cjs) drops a
    # marker when Claude is waiting for the user. Show waiting when an ALIVE session
    # is NOT busy and has a marker. We deliberately do NOT compare timestamps: the native
    # updatedAt is a heartbeat that keeps advancing while a session runs (verified), so a
    # "marker newer than updatedAt" test would be raced by the heartbeat. The rule is
    # purely state-based — a busy (working) or dead session can't need input, so its
    # marker is reaped on sight, which also self-heals a missed `clear`.
    if ($session.SessionId) {
      $nativeSids[$session.SessionId] = $true
      $mk = Join-Path $AttentionDir "$($session.SessionId).json"
      if (Test-Path $mk) {
        if ($isAlive -and -not $session.IsBusy) {
          $session.MarkWaiting()
        } else {
          Remove-Item $mk -ErrorAction SilentlyContinue   # busy or dead: can't need input
        }
      }
    }

    # 3. Enrich with cache-backed transcript data, then stamp relative age.
    #    (Model (from transcript) + CLI version (from session JSON); effort/reasoning
    #    level is not recorded anywhere, so it can't be shown.)
    if ($isAlive) {
      $session.Enrich((Get-SessionActivity $session.Cwd $session.SessionId $session.UpdatedAt))
      # Live hook activity wins over transcript activity, but only while busy. A non-busy
      # session can't be mid-tool, so a lingering marker (missed `stop`) is ignored here
      # and reaped below — purely state-based, matching the attention-marker rule.
      if ($session.IsBusy) { $session.SetActivity((Get-SessionStatus $session.SessionId)) }
      # Live hook prompt (UserPromptSubmit) wins over the transcript-derived guess whenever
      # present — it's the verbatim submitted text. Persists for the whole session.
      $session.SetPrompt((Get-SessionPrompt $session.SessionId))
    }
    $session.StampAge($now)

    $rows += $session
  }

  # Reap orphaned attention markers whose native session file is gone entirely (the
  # per-row reap above only covers sessions still present in $SessionsDir). Keeps
  # ~/.claude/session-attention from growing without bound across many sessions.
  if (Test-Path $AttentionDir) {
    foreach ($mf in Get-ChildItem -Path $AttentionDir -Filter '*.json' -ErrorAction SilentlyContinue) {
      if (-not $nativeSids.ContainsKey($mf.BaseName)) { Remove-Item $mf.FullName -ErrorAction SilentlyContinue }
    }
  }
  # Same reap for live-activity markers whose native session file is gone (a missed
  # `stop`, or the session ended mid-tool). Keeps ~/.claude/session-status bounded.
  if (Test-Path $StatusDir) {
    foreach ($sf in Get-ChildItem -Path $StatusDir -Filter '*.json' -ErrorAction SilentlyContinue) {
      if (-not $nativeSids.ContainsKey($sf.BaseName)) { Remove-Item $sf.FullName -ErrorAction SilentlyContinue }
    }
  }
  # Same reap for last-prompt markers whose native session file is gone. Keeps
  # ~/.claude/session-prompt bounded across many ended sessions.
  if (Test-Path $PromptDir) {
    foreach ($pf in Get-ChildItem -Path $PromptDir -Filter '*.json' -ErrorAction SilentlyContinue) {
      if (-not $nativeSids.ContainsKey($pf.BaseName)) { Remove-Item $pf.FullName -ErrorAction SilentlyContinue }
    }
  }
  # Time out stale terminal links. A link whose Claude process is still alive gets its
  # last-seen stamp refreshed; one whose process has been gone longer than
  # $StaleLinkMs is dropped. Without this, links.json grows without bound because a
  # link is otherwise only forgotten the next time someone clicks it (Focus-Session).
  if ($script:Links.Count -gt 0) {
    $linksDirty = $false
    foreach ($lpid in @($script:Links.Keys)) {
      if ($alive.ContainsKey([int]$lpid)) {
        $script:LinkSeen[$lpid] = $now
      } else {
        $seenAt = if ($script:LinkSeen.ContainsKey($lpid)) { $script:LinkSeen[$lpid] } else { $now }
        if ($now - $seenAt -gt $StaleLinkMs) {
          $script:Links.Remove($lpid); $script:LinkSeen.Remove($lpid); $linksDirty = $true
        } else {
          $script:LinkSeen[$lpid] = $seenAt   # ensure unseen-on-disk links have a stamp
        }
      }
    }
    if ($linksDirty) { Save-Links }
  }

  # Sort: busy first, then alive, then most recently updated
  $rows = @($rows | Sort-Object @{e={ -([int]$_.IsBusy) }}, @{e={ -([int]$_.IsAlive) }}, @{e={ -$_.UpdatedAt }})

  # Overall Claude state drives the status GIF: waiting > running > idle.
  # A dead-process ('stale') session counts as not-active and is ignored here.
  # In the same pass, build the per-session sound-state snapshot (sound is per-session,
  # not overall): map each alive session's row Color to its sound-state key.
  $st = 'idle'
  $snd = @{}
  foreach ($r in $rows) {
    if (-not $r.IsAlive) { continue }
    switch ($r.Color) {
      'waiting' { $snd[$r.SessionId] = 'waiting'; $st = 'waiting' }
      'busy'    { $snd[$r.SessionId] = 'running'; if ($st -ne 'waiting') { $st = 'running' } }
      'idle'    { $snd[$r.SessionId] = 'idle' }
    }
  }
  $script:OverallState = $st
  $script:SndCurStates = $snd

  # Expand the sorted parent list into the flat render order: each parent immediately
  # followed by its live subagents (nested child rows). Children inherit the parent's
  # sort slot, so they always sit directly under the session that spawned them. Only
  # alive parents are scanned — a dead process can't have a running subagent. The
  # parent-only $rows is kept for the count/sound math above; $ordered drives rendering.
  $ordered = New-Object System.Collections.Generic.List[object]
  foreach ($p in $rows) {
    $ordered.Add($p)
    if ($p.IsAlive) {
      foreach ($ch in (Get-LiveSubagents $p.Cwd $p.SessionId $now)) {
        $ch.Pid = $p.Pid        # inherit parent's pid → clicking the child focuses its terminal
        $ch.StampAge($now)
        $ordered.Add($ch)
      }
    }
  }

  # Reconcile the live list against $ordered without clearing it. Reuse each row's
  # existing Border (updating its content in place), create one only for new rows,
  # and move/insert it to the sorted position. Rows that stay put are never removed
  # from the visual tree, so the row under the cursor doesn't flicker on refresh.
  $seen = @{}
  for ($i = 0; $i -lt $ordered.Count; $i++) {
    $r = $ordered[$i]
    $sid = $r.RowKey()
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

  $aliveCount = ($rows | Where-Object { $_.IsAlive -and -not $_.IsSubagent }).Count
  $busyCount  = ($rows | Where-Object { $_.IsBusy -and $_.IsAlive -and -not $_.IsSubagent }).Count
  $sep = [SessionState]::Sep
  $CountText.Text = "$aliveCount active" +
    $(if ($busyCount)  { " $sep $busyCount busy" } else { '' })
  Apply-ListSnapHeight
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

# Background sound downloader: drains $SndQueue, fetching each remote sound to a temp file
# off the UI thread (browser User-Agent defeats hotlink blocks), then records the local
# path in $SndFiles for Resolve-SoundFile to play. Mirrors the GIF downloader above.
$script:SndDlRunspace = [runspacefactory]::CreateRunspace()
$script:SndDlRunspace.Open()
$script:SndDlRunspace.SessionStateProxy.SetVariable('q', $script:SndQueue)
$script:SndDlRunspace.SessionStateProxy.SetVariable('filesMap', $script:SndFiles)
$script:SndDlPs = [powershell]::Create()
$script:SndDlPs.Runspace = $script:SndDlRunspace
[void]$script:SndDlPs.AddScript({
  try {
    [System.Net.ServicePointManager]::SecurityProtocol =
      [System.Net.SecurityProtocolType]::Tls12 -bor
      [System.Net.SecurityProtocolType]::Tls11 -bor
      [System.Net.SecurityProtocolType]::Tls
  } catch {}
  $tmp = [System.IO.Path]::GetTempPath()
  while ($true) {
    $url = $null
    try { if ($q.Count -gt 0) { $url = $q.Dequeue() } } catch {}
    if (-not $url) { Start-Sleep -Milliseconds 120; continue }
    if ($filesMap.ContainsKey($url)) { continue }
    try {
      $req = [System.Net.HttpWebRequest]::Create($url)
      $req.Timeout = 20000; $req.ReadWriteTimeout = 20000; $req.UserAgent = 'Mozilla/5.0'
      $resp = $req.GetResponse()
      $ext = [System.IO.Path]::GetExtension(([Uri]$url).AbsolutePath); if (-not $ext) { $ext = '.mp3' }
      $name = 'overlay-snd-' + ([Math]::Abs($url.GetHashCode())) + $ext
      $dest = Join-Path $tmp $name
      $fs = [System.IO.File]::Create($dest)
      $resp.GetResponseStream().CopyTo($fs)
      $fs.Close(); $resp.Close()
      $filesMap[$url] = $dest
    } catch { $filesMap[$url] = 'FAILED' }
  }
})
$script:SndDlHandle = $script:SndDlPs.BeginInvoke()

# Fast poll so a freshly-downloaded GIF appears promptly (Update-Gif dedups to a cheap
# no-op when nothing has changed).
$gifPollTimer = New-Object System.Windows.Threading.DispatcherTimer
$gifPollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$gifPollTimer.Add_Tick({ Update-Gif })
$gifPollTimer.Start()

# Reconcile the GIF window with the current overall state. Cheap no-op when the
# target GIF path hasn't changed. -force reloads even if the path is unchanged
# (used after the settings dialog edits paths).
function Get-GifPathForState([string]$state) {
  if (-not $script:Gif.enabled) { return '' }

  $primary = [string]$script:Gif.paths[$state]
  if (-not [string]::IsNullOrWhiteSpace($primary)) { return $primary }

  # Never blank the GIF just because Claude entered a state whose GIF is unset.
  # For waiting, prefer the running GIF as a visual "attention" fallback, then idle.
  $fallbackOrder = switch ($state) {
    'waiting' { @('running','idle') }
    'running' { @('waiting','idle') }
    default   { @('running','waiting') }
  }
  foreach ($k in $fallbackOrder) {
    $p = [string]$script:Gif.paths[$k]
    if (-not [string]::IsNullOrWhiteSpace($p)) { return $p }
  }
  return ''
}

# Reconcile the GIF window with the current overall state. Cheap no-op when the
# target GIF path hasn't changed. -force reloads even if the path is unchanged
# (used after the settings dialog edits paths).
function Update-Gif([bool]$force = $false) {
  if (-not $script:gifWindow) { return }
  $want = Get-GifPathForState $script:OverallState
  if (-not $force -and $want -eq $script:GifShownPath) { return }

  if ([string]::IsNullOrWhiteSpace($want)) { Hide-Gif; $script:GifShownPath = $want; return }

  # Already decoded -> show instantly.
  if ($script:GifCache.ContainsKey($want)) { Show-GifPack $script:GifCache[$want]; $script:GifShownPath = $want; return }

  # Local file -> decode now (no network, fast). If the new state's GIF is missing or
  # invalid, keep the previous GIF visible instead of flashing/disappearing.
  if ($want -notmatch '^https?://') {
    $pack = Get-LocalGifPack $want
    if ($pack) {
      $script:GifCache[$want] = $pack
      Show-GifPack $pack
      $script:GifShownPath = $want
    } elseif (-not $script:GifActive) {
      Hide-Gif
      $script:GifShownPath = ''
    }
    return
  }

  # Remote -> have the downloaded bytes arrived (from the background runspace)?
  $b = $script:GifBytes[$want]
  if ($b -is [byte[]]) {
    $ms = New-Object System.IO.MemoryStream(, $b)
    $pack = ConvertTo-GifPack $ms       # decode on UI thread (fast)
    if ($pack) {
      $script:GifCache[$want] = $pack
      Show-GifPack $pack
      $script:GifShownPath = $want
    } elseif (-not $script:GifActive) {
      Hide-Gif
      $script:GifShownPath = ''
    }
    return
  }
  if ($b -eq 'FAILED') {
    # Keep the current GIF on screen. Do not set GifShownPath to the failed target,
    # otherwise a waiting-state download failure blanks the GIF until the state changes.
    if (-not $script:GifActive) { Hide-Gif; $script:GifShownPath = '' }
    return
  }

  # Bytes not here yet: enqueue the download once and LEAVE the current GIF on screen
  # (no freeze, no flicker). Do NOT advance GifShownPath -> the next poll re-checks and
  # shows it the instant the bytes arrive.
  if (-not $script:GifQueued.ContainsKey($want)) { $script:GifQueued[$want] = $true; $script:GifQueue.Enqueue($want) }
}

# ---------------------------------------------------------------------------
# Status sound subsystem: plays a one-shot sound on each PER-SESSION transition between
# states (running/waiting/idle). Unlike the status GIF (which tracks the aggregated overall
# state), sound is evaluated for each individual session, so one session needing input
# chimes even while another already does.
# ---------------------------------------------------------------------------

# The configured sound path for a state, or '' when none / feature disabled.
# Unlike the GIF, sounds do NOT cross-fall back between states: a transition into a
# state with no configured sound is silent (playing another state's sound on the wrong
# transition would be misleading).
function Get-SoundPathForState([string]$state) {
  if (-not $script:Snd.enabled) { return '' }
  if (-not $script:Snd.pathEnabled[$state]) { return '' }
  return [string]$script:Snd.paths[$state]
}

# Resolve a configured sound path to a local file ready for MediaPlayer, or $null if not
# (yet) available. Local paths / file:// URLs resolve immediately; http(s) URLs resolve to
# a downloaded temp file once the background fetcher has it (enqueues the fetch otherwise).
function Resolve-SoundFile([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return $null }
  if ($path -match '^https?://') {
    $f = $script:SndFiles[$path]
    if ($f -is [string] -and $f -ne 'FAILED' -and (Test-Path -LiteralPath $f)) { return $f }
    if ($f -ne 'FAILED' -and -not $script:SndQueued.ContainsKey($path)) {
      $script:SndQueued[$path] = $true; $script:SndQueue.Enqueue($path)
    }
    return $null
  }
  $local = $path -replace '^file:///?', ''
  try { $local = [System.IO.Path]::GetFullPath($local) } catch { return $null }
  if (Test-Path -LiteralPath $local) { return $local }
  return $null
}

# Kick off background downloads for every configured remote sound so a temp file is ready
# before the first transition into that state. Local paths need no prewarm.
function Prewarm-Sounds {
  if (-not $script:Snd.enabled) { return }
  foreach ($k in 'running','waiting','idle') { [void](Resolve-SoundFile ([string]$script:Snd.paths[$k])) }
}

# Play a local sound file through the reused MediaPlayer (restarts from the top each call).
function Play-SoundFile([string]$file) {
  if ([string]::IsNullOrWhiteSpace($file)) { return }
  try {
    if (-not $script:SndPlayer) { $script:SndPlayer = New-Object System.Windows.Media.MediaPlayer }
    $script:SndPlayer.Open([Uri]$file)
    $script:SndPlayer.Volume = [Math]::Max(0.0, [Math]::Min(1.0, [double]$script:Snd.volume))
    $script:SndPlayer.Position = [TimeSpan]::Zero
    $script:SndPlayer.Play()
  } catch {}
}

# Resolve a sound path to a local file SYNCHRONOUSLY (used by the settings "Test" button,
# where blocking briefly on a user click is fine). Remote URLs are fetched inline if not
# already cached. Returns $null if the path is empty or the fetch fails.
function Get-SoundFileSync([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return $null }
  if ($path -match '^https?://') {
    $f = $script:SndFiles[$path]
    if ($f -is [string] -and $f -ne 'FAILED' -and (Test-Path -LiteralPath $f)) { return $f }
    try {
      try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
      $req = [System.Net.HttpWebRequest]::Create($path)
      $req.Timeout = 15000; $req.ReadWriteTimeout = 15000; $req.UserAgent = 'Mozilla/5.0'
      $resp = $req.GetResponse()
      $ext = [System.IO.Path]::GetExtension(([Uri]$path).AbsolutePath); if (-not $ext) { $ext = '.mp3' }
      $dest = Join-Path ([System.IO.Path]::GetTempPath()) ('overlay-snd-' + ([Math]::Abs($path.GetHashCode())) + $ext)
      $fs = [System.IO.File]::Create($dest)
      $resp.GetResponseStream().CopyTo($fs); $fs.Close(); $resp.Close()
      $script:SndFiles[$path] = $dest
      return $dest
    } catch { return $null }
  }
  $local = $path -replace '^file:///?', ''
  try { $local = [System.IO.Path]::GetFullPath($local) } catch { return $null }
  if (Test-Path -LiteralPath $local) { return $local }
  return $null
}

# Reconcile audio with the CURRENT per-session states (rebuilt each tick by Update-List).
# For each alive session, fire its new state's sound exactly once on a transition; a
# session's first observation is a silent baseline (so launching the overlay, or a new
# session appearing, doesn't replay a chorus). While a session holds a nag-enabled state,
# its sound is re-played every `interval`s, up to `max` times per entry (max = 0 = forever);
# the count resets whenever the session changes state. Driven by the 2s refresh tick, so the
# nag config is honoured live with no separate timer. Ended sessions drop out of the maps.
function Update-Sound {
  $cur = $script:SndCurStates
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

  foreach ($sid in @($cur.Keys)) {
    $state = $cur[$sid]
    $was   = $script:SndSessionStates[$sid]

    if ($was -ne $state) {
      # Transition (or first observation): advance the baseline, reset this session's nag.
      $script:SndSessionStates[$sid] = $state
      $script:SndNag[$sid] = @{ lastNag = $now; count = 0 }
      if ($null -ne $was) {                            # first observation stays a silent baseline
        $file = Resolve-SoundFile (Get-SoundPathForState $state)
        if ($file) { Play-SoundFile $file }            # unset / disabled / not-yet-downloaded -> silent
      }
      continue
    }

    # Same state held: re-nag if this state's nag is armed and not yet exhausted.
    $n = $script:Snd.nag[$state]
    if (-not $n -or -not $n.enabled -or [int]$n.interval -le 0) { continue }
    $info = $script:SndNag[$sid]
    if (-not $info) { $info = @{ lastNag = $now; count = 0 }; $script:SndNag[$sid] = $info }
    if ([int]$n.max -gt 0 -and $info.count -ge [int]$n.max) { continue }
    if ($now - $info.lastNag -lt [int]$n.interval * 1000) { continue }
    $file = Resolve-SoundFile (Get-SoundPathForState $state)   # gates enabled + pathEnabled + path
    if ($file) { Play-SoundFile $file; $info.lastNag = $now; $info.count++ }
  }

  # Drop bookkeeping for sessions that ended (no longer in the current snapshot).
  foreach ($sid in @($script:SndSessionStates.Keys)) {
    if (-not $cur.ContainsKey($sid)) { $script:SndSessionStates.Remove($sid); $script:SndNag.Remove($sid) }
  }
}

# Establish silent baselines for every session present at launch so the overlay starts
# quiet — only genuine post-launch transitions chime. Each session's nag clock starts now,
# so a session already waiting at launch still nags once its interval elapses.
function Start-StartupSound {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  foreach ($sid in @($script:SndCurStates.Keys)) {
    $script:SndSessionStates[$sid] = $script:SndCurStates[$sid]
    $script:SndNag[$sid] = @{ lastNag = $now; count = 0 }
  }
}

# Lightweight settings dialog: per-state GIF paths + an enable toggle.
function Show-GifSettings {
  [xml]$sx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Status GIF" Width="380" SizeToContent="Height"
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
  $nb.Text = $script:Gif.paths.waiting
  $ib.Text = $script:Gif.paths.idle
  # NOTE: do NOT use .GetNewClosure() on these handlers. GetNewClosure wraps the block
  # in a new module where $script: resolves to that module (so $script:Gif is $null and
  # the handler throws). The dialog is modal, so these plain scriptblocks keep access to
  # the function's local controls AND the real $script:Gif scope.
  $w.FindName('ResetBtn').Add_Click({ $rb.Text = ''; $nb.Text = ''; $ib.Text = '' })
  $w.FindName('CancelBtn').Add_Click({ $w.Close() })
  $w.FindName('SaveBtn').Add_Click({
    $script:Gif.enabled       = [bool]$en.IsChecked
    $script:Gif.paths.running = $rb.Text.Trim()
    $script:Gif.paths.waiting = $nb.Text.Trim()
    $script:Gif.paths.idle    = $ib.Text.Trim()
    Save-UISettings
    # Paths may have changed -> drop stale decodes + downloaded bytes so new paths reload.
    $script:GifCache.Clear(); $script:GifBytes.Clear(); $script:GifQueued.Clear()
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

function Show-SoundSettings {
  [xml]$sx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Status Sound" Width="380" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen">
  <Border CornerRadius="10" Background="#F2161616" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="14">
    <StackPanel>
      <TextBlock Text="Status sound paths (.wav / .mp3)" Foreground="#FFE6A23C" FontFamily="Segoe UI Semibold" FontSize="13" Margin="0,0,0,10"/>
      <CheckBox x:Name="SndEnabledChk" Content="Play sound on state change" Foreground="#FFFFFFFF" Margin="0,0,0,10"/>
      <TextBlock Text="Running (busy)" Foreground="#80FFFFFF" FontFamily="Segoe UI" FontSize="11"/>
      <DockPanel Margin="0,2,0,2" LastChildFill="True">
        <CheckBox x:Name="SndRunEnChk" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,8,0" ToolTip="Enable this sound"/>
        <TextBox x:Name="SndRunBox"/>
      </DockPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
        <CheckBox x:Name="SndRunNagChk" Content="Re-nag" Foreground="#FFFFFFFF" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock Text="every" Foreground="#80FFFFFF" FontSize="11" VerticalAlignment="Center" Margin="0,0,4,0"/>
        <TextBox x:Name="SndRunNagInt" Width="46" VerticalAlignment="Center"/>
        <TextBlock Text="s," Foreground="#80FFFFFF" FontSize="11" VerticalAlignment="Center" Margin="3,0,8,0"/>
        <TextBox x:Name="SndRunNagMax" Width="38" VerticalAlignment="Center"/>
        <TextBlock Text="times (0 = no limit)" Foreground="#80FFFFFF" FontSize="11" VerticalAlignment="Center" Margin="4,0,0,0"/>
      </StackPanel>
      <TextBlock Text="Needs input" Foreground="#80FFFFFF" FontFamily="Segoe UI" FontSize="11"/>
      <DockPanel Margin="0,2,0,2" LastChildFill="True">
        <CheckBox x:Name="SndNeedEnChk" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,8,0" ToolTip="Enable this sound"/>
        <TextBox x:Name="SndNeedBox"/>
      </DockPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
        <CheckBox x:Name="SndNeedNagChk" Content="Re-nag" Foreground="#FFFFFFFF" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock Text="every" Foreground="#80FFFFFF" FontSize="11" VerticalAlignment="Center" Margin="0,0,4,0"/>
        <TextBox x:Name="SndNeedNagInt" Width="46" VerticalAlignment="Center"/>
        <TextBlock Text="s," Foreground="#80FFFFFF" FontSize="11" VerticalAlignment="Center" Margin="3,0,8,0"/>
        <TextBox x:Name="SndNeedNagMax" Width="38" VerticalAlignment="Center"/>
        <TextBlock Text="times (0 = no limit)" Foreground="#80FFFFFF" FontSize="11" VerticalAlignment="Center" Margin="4,0,0,0"/>
      </StackPanel>
      <TextBlock Text="Idle" Foreground="#80FFFFFF" FontFamily="Segoe UI" FontSize="11"/>
      <DockPanel Margin="0,2,0,2" LastChildFill="True">
        <CheckBox x:Name="SndIdleEnChk" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,8,0" ToolTip="Enable this sound"/>
        <TextBox x:Name="SndIdleBox"/>
      </DockPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
        <CheckBox x:Name="SndIdleNagChk" Content="Re-nag" Foreground="#FFFFFFFF" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock Text="every" Foreground="#80FFFFFF" FontSize="11" VerticalAlignment="Center" Margin="0,0,4,0"/>
        <TextBox x:Name="SndIdleNagInt" Width="46" VerticalAlignment="Center"/>
        <TextBlock Text="s," Foreground="#80FFFFFF" FontSize="11" VerticalAlignment="Center" Margin="3,0,8,0"/>
        <TextBox x:Name="SndIdleNagMax" Width="38" VerticalAlignment="Center"/>
        <TextBlock Text="times (0 = no limit)" Foreground="#80FFFFFF" FontSize="11" VerticalAlignment="Center" Margin="4,0,0,0"/>
      </StackPanel>
      <TextBlock Text="Volume" Foreground="#80FFFFFF" FontFamily="Segoe UI" FontSize="11"/>
      <StackPanel Orientation="Horizontal" Margin="0,2,0,12">
        <Slider x:Name="SndVolSlider" Minimum="0" Maximum="1" Width="270" VerticalAlignment="Center"
                TickFrequency="0.05" IsMoveToPointEnabled="True"/>
        <TextBlock x:Name="SndVolVal" Text="80%" Foreground="#FFFFFFFF" FontFamily="Segoe UI Semibold" FontSize="13" VerticalAlignment="Center" Margin="10,0,0,0" Width="40" TextAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="TestBtn" Content="Test ▶" Width="70" Margin="0,0,8,0"/>
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
  $sen = $w.FindName('SndEnabledChk')
  $srb = $w.FindName('SndRunBox'); $snb = $w.FindName('SndNeedBox'); $sib = $w.FindName('SndIdleBox')
  $sre = $w.FindName('SndRunEnChk'); $sne = $w.FindName('SndNeedEnChk'); $sie = $w.FindName('SndIdleEnChk')
  $svol = $w.FindName('SndVolSlider'); $svval = $w.FindName('SndVolVal')
  $rnc = $w.FindName('SndRunNagChk');  $rni = $w.FindName('SndRunNagInt');  $rnm = $w.FindName('SndRunNagMax')
  $nnc = $w.FindName('SndNeedNagChk'); $nni = $w.FindName('SndNeedNagInt'); $nnm = $w.FindName('SndNeedNagMax')
  $inc = $w.FindName('SndIdleNagChk'); $ini = $w.FindName('SndIdleNagInt'); $inm = $w.FindName('SndIdleNagMax')
  $sen.IsChecked = $script:Snd.enabled
  $srb.Text = $script:Snd.paths.running
  $snb.Text = $script:Snd.paths.waiting
  $sib.Text = $script:Snd.paths.idle
  $sre.IsChecked = $script:Snd.pathEnabled.running
  $sne.IsChecked = $script:Snd.pathEnabled.waiting
  $sie.IsChecked = $script:Snd.pathEnabled.idle
  $svol.Value = [Math]::Max(0.0, [Math]::Min(1.0, [double]$script:Snd.volume))
  $rnc.IsChecked = $script:Snd.nag.running.enabled; $rni.Text = [string]$script:Snd.nag.running.interval; $rnm.Text = [string]$script:Snd.nag.running.max
  $nnc.IsChecked = $script:Snd.nag.waiting.enabled; $nni.Text = [string]$script:Snd.nag.waiting.interval; $nnm.Text = [string]$script:Snd.nag.waiting.max
  $inc.IsChecked = $script:Snd.nag.idle.enabled;    $ini.Text = [string]$script:Snd.nag.idle.interval;    $inm.Text = [string]$script:Snd.nag.idle.max
  $svval.Text = [string][int]([Math]::Round($svol.Value * 100)) + '%'
  $svol.Add_ValueChanged({ $svval.Text = [string][int]([Math]::Round($svol.Value * 100)) + '%' })
  # NOTE: do NOT use .GetNewClosure() on these handlers (see Show-GifSettings). The dialog
  # is modal, so these plain scriptblocks keep access to the local controls AND $script:Snd.
  $w.FindName('ResetBtn').Add_Click({
    $srb.Text = ''; $snb.Text = ''; $sib.Text = ''
    $sre.IsChecked = $true; $sne.IsChecked = $true; $sie.IsChecked = $true
    $rnc.IsChecked = $false; $rni.Text = '60'; $rnm.Text = '0'
    $nnc.IsChecked = $true;  $nni.Text = '60'; $nnm.Text = '0'
    $inc.IsChecked = $false; $ini.Text = '60'; $inm.Text = '0'
  })
  # Test plays whichever sound box is filled (running first), resolving the path right now
  # so a freshly-typed URL is fetched and heard without needing to Save or wait.
  $w.FindName('TestBtn').Add_Click({
    $p = $srb.Text.Trim(); if (-not $p) { $p = $snb.Text.Trim() }; if (-not $p) { $p = $sib.Text.Trim() }
    $script:Snd.volume = [Math]::Max(0.0, [Math]::Min(1.0, [double]$svol.Value))  # Test honors the slider live
    $f = Get-SoundFileSync $p
    if ($f) { Play-SoundFile $f }
  })
  $w.FindName('CancelBtn').Add_Click({ $w.Close() })
  $w.FindName('SaveBtn').Add_Click({
    $script:Snd.enabled       = [bool]$sen.IsChecked
    $script:Snd.volume        = [Math]::Max(0.0, [Math]::Min(1.0, [double]$svol.Value))
    $script:Snd.paths.running = $srb.Text.Trim()
    $script:Snd.paths.waiting = $snb.Text.Trim()
    $script:Snd.paths.idle    = $sib.Text.Trim()
    $script:Snd.pathEnabled.running = [bool]$sre.IsChecked
    $script:Snd.pathEnabled.waiting = [bool]$sne.IsChecked
    $script:Snd.pathEnabled.idle    = [bool]$sie.IsChecked
    # Parse nag fields defensively: interval >= 1s, max >= 0 (0 = unlimited); blank/garbage -> keep prior.
    $parseInt = { param($txt, $cur, $min) $v = 0; if ([int]::TryParse(($txt.Trim()), [ref]$v)) { [Math]::Max($min, $v) } else { $cur } }
    $script:Snd.nag.running.enabled  = [bool]$rnc.IsChecked
    $script:Snd.nag.running.interval = & $parseInt $rni.Text $script:Snd.nag.running.interval 1
    $script:Snd.nag.running.max      = & $parseInt $rnm.Text $script:Snd.nag.running.max 0
    $script:Snd.nag.waiting.enabled  = [bool]$nnc.IsChecked
    $script:Snd.nag.waiting.interval = & $parseInt $nni.Text $script:Snd.nag.waiting.interval 1
    $script:Snd.nag.waiting.max      = & $parseInt $nnm.Text $script:Snd.nag.waiting.max 0
    $script:Snd.nag.idle.enabled     = [bool]$inc.IsChecked
    $script:Snd.nag.idle.interval    = & $parseInt $ini.Text $script:Snd.nag.idle.interval 1
    $script:Snd.nag.idle.max         = & $parseInt $inm.Text $script:Snd.nag.idle.max 0
    Save-UISettings
    Prewarm-Sounds      # fetch any newly-entered remote sounds so the next transition plays
    # Per-session re-nag re-reads $script:Snd.nag live every tick, so changed nag settings
    # take effect on the next refresh with no timer to (re)arm here.
    $w.Close()
  })
  $w.Add_Loaded({
    try {
      $hh = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
      if ($hh -ne [IntPtr]::Zero) { [WinTools]::Focus($hh) }
    } catch {}
    $srb.Focus() | Out-Null
    [System.Windows.Input.Keyboard]::Focus($srb) | Out-Null
  })
  [void]$w.ShowDialog()
}

$GifBtn.Add_Click({ Show-GifSettings })
$SndBtn.Add_Click({ Show-SoundSettings })

# Reflect the current auto-fit cap on the header button (e.g. "⤢3").
function Update-FitButton {
  if ($FitBtn) { $FitBtn.Content = ([char]0x2922).ToString() + [int]$script:UI.autoFitCap }
}

function Show-FitSettings {
  [xml]$fx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Auto-fit" Width="300" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen">
  <Border CornerRadius="10" Background="#F2161616" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="14">
    <StackPanel>
      <TextBlock Text="Auto-fit cap" Foreground="#FFE6A23C" FontFamily="Segoe UI Semibold" FontSize="13" Margin="0,0,0,8"/>
      <TextBlock Text="The list auto-grows to show every session, but only while the total is at or below this many. Above it, extra rows scroll." Foreground="#80FFFFFF" FontFamily="Segoe UI" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,12"/>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
        <Slider x:Name="CapSlider" Minimum="1" Maximum="12" Width="200" VerticalAlignment="Center"
                TickFrequency="1" IsSnapToTickEnabled="True" IsMoveToPointEnabled="True"/>
        <TextBlock x:Name="CapVal" Text="3" Foreground="#FFFFFFFF" FontFamily="Segoe UI Semibold" FontSize="14" VerticalAlignment="Center" Margin="10,0,0,0" Width="24" TextAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="CancelBtn" Content="Cancel" Width="70" Margin="0,0,8,0"/>
        <Button x:Name="SaveBtn" Content="Save" Width="70"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
  $r = New-Object System.Xml.XmlNodeReader $fx
  $w = [Windows.Markup.XamlReader]::Load($r)
  $sl = $w.FindName('CapSlider'); $lbl = $w.FindName('CapVal')
  $sl.Value = [Math]::Max(1, [Math]::Min(12, [int]$script:UI.autoFitCap))
  $lbl.Text = [string][int]$sl.Value
  # Plain scriptblocks (no GetNewClosure) so $script: stays the real overlay scope.
  $sl.Add_ValueChanged({ $lbl.Text = [string][int]$sl.Value })
  $w.FindName('CancelBtn').Add_Click({ $w.Close() })
  $w.FindName('SaveBtn').Add_Click({
    $script:UI.autoFitCap = [Math]::Max(1, [Math]::Min(12, [int]$sl.Value))
    Save-UISettings
    Update-FitButton
    # Apply the new cap immediately (grow-only): fit the current rows if within cap.
    if ($List.Items.Count -le [int]$script:UI.autoFitCap -and [int]$script:UI.visibleRows -lt $List.Items.Count) {
      $script:UI.visibleRows = [int]$List.Items.Count
    }
    Apply-ListSnapHeight
    $w.Close()
  })
  $w.Add_Loaded({
    try {
      $hh = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
      if ($hh -ne [IntPtr]::Zero) { [WinTools]::Focus($hh) }
    } catch {}
    $sl.Focus() | Out-Null
  })
  [void]$w.ShowDialog()
}

$FitBtn.Add_Click({ Show-FitSettings })
Update-FitButton

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

# Initial render + refresh timer. The per-session re-nag is folded into Update-Sound (driven
# by the 2s tick below), so there is no separate nag timer to arm here.
Update-List
Update-Gif         # lazy-loads the current state's GIF; cached + instant on later switches
Prewarm-Sounds     # pre-download remote sounds so transitions aren't silent
Start-StartupSound # record silent per-session baselines so launch is quiet
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Update-List; Update-Gif; Update-Sound })
$timer.Start()

# Always-on-top + show-on-all-desktops. Primary: ask Windows to pin the window
# (Windows-side, no polling). Fallback: if pinning isn't available, a light timer
# keeps the overlay on the active desktop so it follows you across desktops.
$script:overlayHwnd = [IntPtr]::Zero
$script:pinned = $false

$followTimer = New-Object System.Windows.Threading.DispatcherTimer
$followTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$followTimer.Add_Tick({
  if ($script:overlayHwnd -ne [IntPtr]::Zero) { [VD]::Follow($script:overlayHwnd) }
})

# Re-assert HWND_TOPMOST on a steady timer. Shell-pinning keeps the overlay across
# virtual desktops but does NOT defend z-order, and WPF's Topmost is silently dropped
# when a terminal (or any app) grabs the top slot — so without this the overlay falls
# behind until relaunch. NOACTIVATE means this never steals focus.
$topmostTimer = New-Object System.Windows.Threading.DispatcherTimer
$topmostTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$topmostTimer.Add_Tick({
  if ($script:overlayHwnd -eq [IntPtr]::Zero) { return }
  # Skip the re-assert while the mouse is over the overlay: that's exactly when a row's
  # hover ToolTip is showing, and the ToolTip renders in its own popup window. Pushing the
  # overlay back to HWND_TOPMOST would re-stack it above that popup and hide the tooltip.
  # When the mouse is over the overlay it is already on top (you couldn't hover it otherwise),
  # so skipping here costs no z-order safety — other apps only grab the top slot when you're
  # interacting with them, i.e. the mouse is NOT over the overlay.
  if ($Window.IsMouseOver) { return }
  [WinTools]::ReassertTopmost($script:overlayHwnd)
})

# Pin the overlay: always-on-top + pinned/followed across every virtual desktop.
function Set-Pinned {
  $Window.Topmost = $true
  $h = $script:overlayHwnd
  if ($h -ne [IntPtr]::Zero) { $script:pinned = [Pinner]::Pin($h) }
  if ($script:pinned) { $followTimer.Stop() } else { $followTimer.Start() }
  $topmostTimer.Start()   # always defend z-order, pinned or not
}

# One-shot, ~600ms after show (the shell has registered the window as a view by then):
# pin the overlay.
$pinTimer = New-Object System.Windows.Threading.DispatcherTimer
$pinTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$pinTimer.Add_Tick({
  $pinTimer.Stop()
  $script:overlayHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
  Set-Pinned
})
$pinTimer.Start()

$Window.Add_Closed({
  $timer.Stop(); $followTimer.Stop(); $pinTimer.Stop(); $topmostTimer.Stop(); $gifDesktopTimer.Stop()
  if ($gifPollTimer) { $gifPollTimer.Stop() }
  if ($script:GifTimer) { $script:GifTimer.Stop() }
  $script:GifActive = $null
  if ($script:GifCache) { $script:GifCache.Clear() }
  try { if ($script:SndPlayer) { $script:SndPlayer.Stop(); $script:SndPlayer.Close() } } catch {}
  try { if ($script:SndDlPs) { $script:SndDlPs.Stop(); $script:SndDlPs.Dispose() } } catch {}
  try { if ($script:SndDlRunspace) { $script:SndDlRunspace.Close(); $script:SndDlRunspace.Dispose() } } catch {}
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

# Clean up the PID file on normal exit — but only if it still points at us, so we
# never delete a newer instance's record (the one that killed and replaced us).
try {
  if (Test-Path $script:OverlayPidFile) {
    $cur = Get-Content $script:OverlayPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cur -eq "$PID") { Remove-Item $script:OverlayPidFile -ErrorAction SilentlyContinue }
  }
} catch {}