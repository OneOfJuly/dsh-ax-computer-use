#Requires -Version 5.1
# axc.ps1 - Windows engine for ax-computer-use v2 (P1+P2)
# Contract twin of src/axc.swift (macOS) / axc.py (Linux): same subcommands, same
# output grammar (OK confirmed/unverified/suspected_noop, SUMMARY, FOCUS, MAP for
# shots, HIT «...» @x,y OCR, VERIFY FAIL / FORM_ERROR / OCR MISS).
# Stack: UIA (System.Windows.Automation) tree, SendInput (P/Invoke) HID input,
# CopyFromScreen JPEG shots, Windows.Media.Ocr OCR with word coordinates.
# Zero external dependencies: PowerShell 5.1 + .NET 4.x ship with Windows 10/11.

param()
$ErrorActionPreference = 'Continue'
$script:FRONT_WARN = ''
$script:UHOME = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }  # mac pwsh testing
$script:TMPD  = if ($env:TEMP) { $env:TEMP } else { '/tmp' }
$script:CACHE_FILE = Join-Path $script:UHOME '.ax-cu/cache.json'
$script:LASTSHOT   = Join-Path $script:TMPD 'axc-lastshot.json'
$ERR_PATS = @('不能','必须','请输入','请选择','错误','超出','失败',
              'invalid','required','error','exceed','must be')

# Windows-only assemblies; fail silently so non-Windows hosts can still run the
# pure-data subcommands (remember/recall/wait) and we get clean smoke-test output.
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Continue'

# ---- SendInput P/Invoke (HID-grade: reaches Chromium renderers, unlike UIA calls) ----
$ErrorActionPreference = 'SilentlyContinue'  # user32 P/Invoke cannot compile off-Windows; hide noise
if (-not ('AxWin.Native' -as [type])) {
Add-Type -Namespace AxWin -Name Native -MemberDefinition @"
[DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
"@
}
$ErrorActionPreference = 'Continue'
$MOUSE_MOVE=0x0001; $MOUSE_LEFTDOWN=0x0002; $MOUSE_LEFTUP=0x0004
$KEY_UP=0x0002; $KEY_UNICODE=0x0004

function Send-Mouse([int]$x,[int]$y,[switch]$click) {
  [AxWin.Native]::SetCursorPos($x,$y) | Out-Null; Start-Sleep -Milliseconds 60
  if ($click) {
    $i=[AxWin.Native+INPUT[]]::new(2)
    $i[0].type=0; $i[0].u.mi.dwFlags=$MOUSE_LEFTDOWN
    $i[1].type=0; $i[1].u.mi.dwFlags=$MOUSE_LEFTUP
    [AxWin.Native]::SendInput(2,$i,[Runtime.InteropServices.Marshal]::SizeOf([type][AxWin.Native+INPUT])) | Out-Null
  }
}
function Send-Text([string]$text) {  # HID-grade unicode typing (chord of KEYEVENTF_UNICODE)
  foreach ($ch in $text.ToCharArray()) {
    $i=[AxWin.Native+INPUT[]]::new(2)
    $i[0].type=1; $i[0].u.ki.wScan=[uint16][char]$ch; $i[0].u.ki.dwFlags=$KEY_UNICODE
    $i[1].type=1; $i[1].u.ki.wScan=[uint16][char]$ch; $i[1].u.ki.dwFlags=$KEY_UNICODE -bor $KEY_UP
    [AxWin.Native]::SendInput(2,$i,[Runtime.InteropServices.Marshal]::SizeOf([type][AxWin.Native+INPUT])) | Out-Null
    Start-Sleep -Milliseconds 10
  }
}
$VKEYS=@{return=0x0D;enter=0x0D;tab=0x09;esc=0x1B;escape=0x1B;space=0x20;backspace=0x08;delete=0x2E;up=0x26;down=0x28;left=0x25;right=0x27;home=0x24;end=0x23;pageup=0x21;pagedown=0x22}
function Send-Key([string]$spec) {  # "return" / "ctrl+a" / "shift+tab"
  $parts=$spec.ToLower() -split '\+'
  $mods=@(); if ($parts.Count -gt 1) { $mods=$parts[0..($parts.Count-2)] }
  $key=$parts[-1]
  $vk = if ($key.Length -eq 1) { [uint16][char]::ToUpperInvariant($key[0]) } else { $VKEYS[$key] }
  if (-not $vk) { throw "unknown key '$key'" }
  $seq=@()
  foreach ($m in $mods) {
    $mvk = switch ($m) { ctrl{0x11} alt{0x12} shift{0x10} win{0x5B} default{0} }
    if ($mvk -eq 0) { throw "unknown modifier '$m'" }
    $kd=[AxWin.Native+INPUT]::new(); $kd.type=1; $kd.u.ki.wVk=[uint16]$mvk; $seq+=$kd
  }
  $kd=[AxWin.Native+INPUT]::new(); $kd.type=1; $kd.u.ki.wVk=$vk; $seq+=$kd
  $ku=[AxWin.Native+INPUT]::new(); $ku.type=1; $ku.u.ki.wVk=$vk; $ku.u.ki.dwFlags=$KEY_UP; $seq+=$ku
  for ($j=$mods.Count-1; $j -ge 0; $j--) {
    $mvk = switch ($mods[$j]) { ctrl{0x11} alt{0x12} shift{0x10} win{0x5B} default{0} }
    $ku2=[AxWin.Native+INPUT]::new(); $ku2.type=1; $ku2.u.ki.wVk=[uint16]$mvk; $ku2.u.ki.dwFlags=$KEY_UP; $seq+=$ku2
  }
  $arr=[AxWin.Native+INPUT[]]::new($seq.Count); $k=0
  foreach ($e in $seq) { $arr[$k]=$e; $k++ }
  [AxWin.Native]::SendInput($arr.Count,$arr,[Runtime.InteropServices.Marshal]::SizeOf([type][AxWin.Native+INPUT])) | Out-Null
}

function Get-FrontPid {
  try {
    $h=[AxWin.Native]::GetForegroundWindow()
    if (-not $h -or $h -eq [IntPtr]::Zero) { return 0 }
    $p=0u; [AxWin.Native]::GetWindowThreadProcessId($h,[ref]$p) | Out-Null; return [int]$p
  } catch { return 0 }
}
function Guard-Front([int]$tpid) {
  if ($tpid -le 0) { return }
  if ((Get-FrontPid) -eq $tpid) { return }
  $proc = Get-Process -Id $tpid -ErrorAction SilentlyContinue
  if ($proc -and $proc.MainWindowHandle -ne 0) {
    [AxWin.Native]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 500
  }
  if ((Get-FrontPid) -ne $tpid) { $script:FRONT_WARN = " WARN_FRONT pid=$(Get-FrontPid) (wanted $tpid)" }
}

function Parse-Args($argv) {
  # supports both "--key value" and "--key=value" (index.js uses bare form)
  $a=@{}
  $i=1  # skip subcommand at $argv[0] when called via -File (args only), else 1 covers it
  if ($argv.Count -gt 0 -and $argv[0] -notmatch '^--') { $i=1 } else { $i=0 }
  while ($i -lt $argv.Count) {
    $t=$argv[$i]
    if ($t -notmatch '^--') { $i++; continue }
    if ($t -match '^--([^=]+)=(.*)$') { $a[$Matches[1]]=$Matches[2] }
    elseif ($i+1 -lt $argv.Count -and $argv[$i+1] -notmatch '^--') { $a[$t.Substring(2)]=$argv[$i+1]; $i++ }
    else { $a[$t.Substring(2)]='1' }
    $i++
  }
  return $a
}
function Get-TargetPid($a) { if ($a['pid']) { return [int]$a['pid'] } else { return 0 } }

# ---- winlist ----
function Cmd-Winlist($a) {
  $filter = $null
  if ($a.ContainsKey('pid') -and $a['pid']) { $filter=[int]$a['pid'] }
  Get-Process | Where-Object { $_.MainWindowTitle -ne '' -and $_.MainWindowHandle -ne 0 } | ForEach-Object {
    if ($filter -and $_.Id -ne $filter) { return }
    Write-Output "$($_.MainWindowHandle) pid$($_.Id) $($_.ProcessName) «$($_.MainWindowTitle)»"
  }
}

# ---- UIA tree access (shared by axtree / press / set / verify / read_errors) ----
$script:UIA_AUTO = [System.Windows.Automation.Automation]

function Get-AppRoots([int]$tpid) {
  $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $tpid)
  $roots = $script:UIA_AUTO::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
  if ($roots.Count -eq 0) { return $roots }
  # activate nudge: Chromium UIA trees need a touch like macOS AXManualAccessibility
  $roots[0].SetFocus()
  Start-Sleep -Milliseconds 400
  return $roots
}

function Walk-UIA([int]$tpid, [string]$textF, [string]$roleF, [int]$nth) {
  # returns the nth matching element @(el,name,value,role), or $null
  # NB: nested PS functions can't see caller locals — walk state lives in $script:
  $script:WALK_FOUND = 0
  $script:WALK_HIT = $null
  function Rec($el, [int]$d) {
    if ($d -gt 24 -or $script:WALK_HIT) { return }
    try {
      $name = $el.Current.Name
      $val = ''
      try { $val = $el.Current.ValuePattern.Current.Value } catch {}
      if (-not $val) { try { $val = $el.Current.LegacyIAccessiblePattern.Current.Value } catch {} }
      $role = $el.Current.ControlType.ProgrammaticName -replace '^ControlType\.',''
      $hay = "$name $val".ToLower()
      $okT = (-not $textF) -or ($hay.Contains($textF.ToLower()))
      $okR = (-not $roleF) -or ($role.ToLower().Contains($roleF.ToLower()))
      if ($okT -and $okR) {
        if ($script:WALK_FOUND -eq $nth) { $script:WALK_HIT = @($el,$name,$val,$role); return }
        $script:WALK_FOUND++
      }
      $kids = $el.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
      foreach ($k in $kids) { Rec $k ($d+1) }
    } catch {}
  }
  foreach ($w in (Get-AppRoots $tpid)) { Rec $w 0 }
  return $script:WALK_HIT
}

function Invoke-Element($el) {
  # semantic press: Invoke > Toggle > ExpandCollapse > LegacyIAccessible.DoDefaultAction
  try { $p=$el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $p.Invoke(); return 'invoke' } catch {}
  try { $p=$el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern); $p.Toggle(); return 'toggle' } catch {}
  try { $p=$el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern); $p.Expand(); return 'expand' } catch {}
  try { $p=$el.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern); $p.DoDefaultAction(); return 'legacy' } catch {}
  return $null
}

function Set-ElementValue($el, [string]$v) {
  try { $p=$el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); $p.SetValue($v); return $true } catch {}
  return $false
}

function Get-ElCenter($el) {
  try { $r=$el.Current.BoundingRectangle; return @([int]($r.X+$r.Width/2), [int]($r.Y+$r.Height/2)) } catch {}
  return $null
}

function Read-VerifyValue($vf, [int]$tpid) {
  # verify:{text|role|nth, contains, wait} -> value string (throws if not found)
  $el = Walk-UIA $tpid $vf['text'] $vf['role'] $(if ($vf['nth']) { [int]$vf['nth'] } else { 0 })
  if (-not $el) { throw "verify target not found «$($vf['text'])»" }
  return $el[2]  # stored value snapshot (fresh read would need a second walk; value read at walk time)
}

# ---- axtree (UIA) ----
function Cmd-Axtree($a) {
  $tpid = Get-TargetPid $a
  $depthMax = if ($a['depth']) { [int]$a['depth'] } else { 9 }
  $nodeCap  = if ($a['max'])   { [int]$a['max'] }   else { 900 }
  $textF    = $a['text']
  $menuMode = $a['menu']
  $roots = Get-AppRoots $tpid
  if ($roots.Count -eq 0) { Write-Output "NODES 0"; Write-Output "FILTER «$textF» no app window for pid $tpid"; return }
  $script:count=0
  function Dump($el,[int]$d,[string]$chain) {
    if ($script:count -ge $nodeCap -or $d -gt $depthMax) { return }
    $script:count++
    $name=$el.Current.Name
    $role=$el.Current.ControlType.ProgrammaticName -replace '^ControlType\.',''
    # menu pruning like macOS engine: skip menu-bar/menu subtrees unless --menu
    if (-not $menuMode -and ($role -eq 'MenuBar' -or $role -eq 'Menu')) { return }
    $val=''
    try { $val=$el.Current.ValuePattern.Current.Value } catch {}
    if (-not $val) { try { $val=$el.Current.LegacyIAccessiblePattern.Current.Value } catch {} }
    $line="$chain$role t=$(if($name){$name}else{'-'})" + $(if($val){" v=$val"})
    if (-not $textF -or $line.ToLower().Contains($textF.ToLower())) { Write-Output $line }
    $kids=$el.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
    $i=0
    foreach ($k in $kids) { Dump $k ($d+1) "$chain$i."; $i++ }
  }
  $ri=0
  foreach ($w in $roots) { Write-Output "[:$(($w.Current.ControlType.ProgrammaticName) -replace '^ControlType\.','')] window#$ri"; Dump $w 0 ''; $ri++ }
  Write-Output "NODES $($script:count)"
}

# ---- axread (chain walk "1.0.2" from first app window) ----
function Cmd-Axread($a) {
  $tpid = Get-TargetPid $a
  $chain = if ($a['path']) { $a['path'] } elseif ($a['chain']) { $a['chain'] } else { '' }
  if (-not $chain) { Write-Output 'ERR axread needs --path 1.0.2'; return }
  $roots = Get-AppRoots $tpid
  if ($roots.Count -eq 0) { Write-Output "ERR axread: no app window for pid $tpid"; return }
  $el = $roots[0]
  foreach ($ix in ($chain -split '\.' | ForEach-Object { [int]$_ })) {
    $kids = $el.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    if ($ix -ge $kids.Count) { Write-Output "ERR axread: chain '$chain' out of range at $ix"; return }
    $el = $kids[$ix]
  }
  $name=$el.Current.Name
  $role=$el.Current.ControlType.ProgrammaticName -replace '^ControlType\.',''
  $val=''
  try { $val=$el.Current.ValuePattern.Current.Value } catch {}
  if (-not $val) { try { $val=$el.Current.LegacyIAccessiblePattern.Current.Value } catch {} }
  $r=$el.Current.BoundingRectangle
  Write-Output "role=$role t=$(if($name){$name}else{'-'}) v=$val frame=$([int]$r.X),$([int]$r.Y),$([int]$r.Width),$([int]$r.Height)"
}

# ---- shot (JPEG + MAP line for click{shot:[px,py]}) ----
function Capture-Screen([string]$out, [int]$maxL, [int]$targetPid) {
  $vs=[System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp=New-Object System.Drawing.Bitmap $vs.Width,$vs.Height
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($vs.X,$vs.Y,0,0,$bmp.Size)
  $ox=$vs.X; $oy=$vs.Y; $w=$vs.Width; $h=$vs.Height
  if ($targetPid -gt 0) {  # window-scoped crop
    $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $r=New-Object AxWin.Native+RECT
      if ([AxWin.Native]::GetWindowRect($proc.MainWindowHandle,[ref]$r)) {
        $w=$r.R-$r.L; $h=$r.B-$r.T; $ox=$r.L; $oy=$r.T
        $crop=$bmp.Clone([System.Drawing.Rectangle]::new($r.L-$vs.X,$r.T-$vs.Y,$w,$h), $bmp.PixelFormat)
        $g.Dispose(); $bmp.Dispose(); $bmp=$crop
      }
    }
  }
  $scale=1.0
  if ($w -gt $maxL -or $h -gt $maxL) {
    $scale=$maxL/[double][Math]::Max($w,$h)
    $bmp2=New-Object System.Drawing.Bitmap ([int]($w*$scale)),([int]($h*$scale))
    $g2=[System.Drawing.Graphics]::FromImage($bmp2); $g2.InterpolationMode='HighQualityBicubic'
    $g2.DrawImage($bmp,0,0,$bmp2.Width,$bmp2.Height); $bmp.Dispose(); $bmp=$bmp2
  }
  $bmp.Save($out,[System.Drawing.Imaging.ImageFormat]::Jpeg)
  $bmp.Dispose()
  return @{w=$w; h=$h; scale=$scale; ox=$ox; oy=$oy}
}

function Cmd-Shot($a) {
  $out = if ($a['out']) { $a['out'] } else { Join-Path $script:TMPD 'axc-shot.jpg' }
  $maxL = if ($a['max']) { [int]$a['max'] } else { 1280 }
  $m = Capture-Screen $out $maxL (Get-TargetPid $a)
  Write-Output "SAVED $out"
  Write-Output ("MAP w={0} h={1} max={2} scale={3:F4} origin={4},{5}" -f $m.w,$m.h,$m.maxL,$m.scale,$m.ox,$m.oy)
  @{pid=(Get-TargetPid $a); w=$m.w; h=$m.h; scale=$m.scale; ox=$m.ox; oy=$m.oy; out=$out} |
    ConvertTo-Json -Compress | Set-Content -Path $script:LASTSHOT -Encoding UTF8
}

function Shot-To-Screen([int]$tpid, [double]$px, [double]$py) {
  if (-not (Test-Path $script:LASTSHOT)) { throw "no recent shot (MAP) to map shot:[$px,$py] — run ax_shot first" }
  $m = Get-Content $script:LASTSHOT | ConvertFrom-Json
  if ($tpid -gt 0 -and $m.pid -gt 0 -and $m.pid -ne $tpid) { throw "last shot was pid $($m.pid), not $tpid" }
  return @([int]($m.ox + $px/$m.scale), [int]($m.oy + $py/$m.scale))
}

# ---- WinRT OCR helper (must load before first use) ----
if (-not ('WinRTHelper' -as [type])) {
Add-Type -TypeDefinition @"
public static class WinRTHelper { public static T Await<T>(this Windows.Foundation.IAsyncOperation<T> op) {
  var ev=new System.Threading.ManualResetEvent(false); op.Completed = (o,s)=>ev.Set(); ev.WaitOne(15000); return o.GetResults(); } }
"@ | Out-Null
}
try {
  [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime] | Out-Null
  [Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime] | Out-Null
  Update-TypeData -TypeName Windows.Foundation.IAsyncOperation`1 -MemberName AwaitOperation -MemberType ScriptMethod -Value { return [WinRTHelper]::Await($this) } -Force | Out-Null
  $script:OCR_READY = $true
} catch { $script:OCR_READY = $false }

function Get-OcrHits([string]$png) {
  # returns @( @(text,cx,cy), ... ) line-grouped, screen-pixel coordinates
  if (-not $script:OCR_READY) { throw 'Windows OCR runtime unavailable' }
  $eng=[Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if (-not $eng) { throw 'no OCR engine for user languages' }
  $stream=[IO.File]::OpenRead($png)
  try {
    $dec=[Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream).AwaitOperation()
    $bmp=($dec.GetSoftwareBitmapAsync().AwaitOperation())
    $res=$eng.RecognizeAsync($bmp).AwaitOperation()
    $hits=@()
    foreach ($line in $res.Lines) {
      $txt=($line.Text -join ' ')
      $x0=[double]$line.Words[0].BoundingRect.X; $y0=[double]$line.Words[0].BoundingRect.Y
      $last=$line.Words[$line.Words.Count-1].BoundingRect
      $cx=[int](($x0 + $last.X + $last.Width)/2); $cy=[int](($y0 + $last.Y + $last.Height)/2)
      $hits+=,@($txt,$cx,$cy)
    }
    return ,$hits
  } finally { $stream.Close() }
}

function Get-OcrMatches([int]$tpid, [string]$filt) {
  # full-res PNG so word boxes are screen pixels directly
  $png = Join-Path $script:TMPD 'axc-ocr.png'
  Capture-Screen $png 99999 $tpid | Out-Null
  $hits = Get-OcrHits $png
  if ($filt) { $hits = @($hits | Where-Object { $_[0].ToLower().Contains($filt.ToLower()) }) }
  return $hits
}

function Cmd-Ocr($a) {
  $want = if ($a['text']) { $a['text'] } else { '' }
  try { $hits = Get-OcrMatches (Get-TargetPid $a) $want } catch { Write-Output "ERR $($_.Exception.Message)"; return }
  if ($a['assert_absent']) {
    if ((Get-TargetPid $a) -le 0) { Write-Output 'ERR cannot assert absence without --pid (window may be hidden)'; return }
    if ($hits.Count -gt 0) {
      Write-Output "ASSERT ABSENT FAIL: found $($hits.Count) hits for «$want»"
      for ($i=0; $i -lt [Math]::Min(3,$hits.Count); $i++) { Write-Output "  HIT «$($hits[$i][0])» @($($hits[$i][1]),$($hits[$i][2]))" }
      return
    }
    Write-Output "OK absent «$want»"
    return
  }
  if ($hits.Count -eq 0) { Write-Output 'NO MATCH' }
  for ($i=0; $i -lt [Math]::Min(40,$hits.Count); $i++) {
    $t=$hits[$i][0]; if ($t.Length -gt 80) { $t=$t.Substring(0,80) }
    Write-Output "HIT «$t» @($($hits[$i][1]),$($hits[$i][2]))"
  }
}

# ---- cache (remember / recall; shared format with macOS/Linux engines) ----
function Load-Cache {
  $dir = Split-Path $script:CACHE_FILE
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path $script:CACHE_FILE) {
    try { return (Get-Content $script:CACHE_FILE -Raw | ConvertFrom-Json) } catch { return @{} }
  }
  return @{}
}
function Save-Cache($c) { $c | ConvertTo-Json -Depth 5 | Set-Content -Path $script:CACHE_FILE -Encoding UTF8 }
function Cache-Key($act, [int]$tpid) {
  $app = '0'
  if ($act.app) { $app=$act.app } elseif ($tpid -gt 0) { $app="$tpid" }
  $k='?'; if ($act.key) { $k=$act.key }
  return "$app`:$k"
}

# ---- relaunch ----
function Cmd-Relaunch($a) {
  $app=$a['app']; $appArgs=$a['args']
  $procs=Get-Process -Name $app -ErrorAction SilentlyContinue
  foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  if ($procs) { Start-Sleep -Milliseconds 800 }
  Start-Process -FilePath $app -ArgumentList $appArgs
  for ($i=0; $i -lt 24; $i++) {
    Start-Sleep -Milliseconds 250
    $np=Get-Process -Name $app -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($np) { Write-Output "OK relaunch pid=$($np.Id)"; return }
  }
  Write-Output 'ERR relaunch: process not found after start'
}

# ---- axact (batched verified actions; v2 op set) ----
function Cmd-Axact($a) {
  $tpid = Get-TargetPid $a
  $acts = $a['json'] | ConvertFrom-Json
  $idx=0; $c=0;$u=0;$n=0;$e=0; $abort=''
  $focusBefore = Get-FrontPid
  foreach ($act in $acts) {
    $op=$act.op; $msg=''
    try {
      switch ($op) {
        'click' {
          Guard-Front $tpid
          $x=0; $y=0
          if ($act.shot) {
            $xy = Shot-To-Screen $tpid ([double]$act.shot[0]) ([double]$act.shot[1])
            $x=$xy[0]; $y=$xy[1]
          } elseif ($act.text) {
            $el = Walk-UIA $tpid $act.text $act.role $(if ($act.nth) { [int]$act.nth } else { 0 })
            if (-not $el) { throw "click: no element «$($act.text)»" }
            $ctr = Get-ElCenter $el[0]
            if (-not $ctr) { throw "click: element has no position «$($act.text)»" }
            $x=$ctr[0]; $y=$ctr[1]
          } else { $x=[int]$act.x; $y=[int]$act.y }
          Send-Mouse $x $y -click
          Start-Sleep -Milliseconds 300
          $msg="OK confirmed ${idx}click @($x,$y)"
          $c++
          if ($act.verify) {
            Start-Sleep -Milliseconds $(if ($act.verify.wait) { [int]$act.verify.wait } else { 800 })
            $v = Read-VerifyValue $act.verify $tpid
            if ($act.verify.contains) {
              if (-not $v -or -not $v.ToLower().Contains($act.verify.contains.ToLower())) {
                throw "VERIFY FAIL click: got v=«$v» expected contains «$($act.verify.contains)»"
              }
              $msg += " verified v=«$($v.Substring(0,[Math]::Min(40,$v.Length)))»"
            } elseif (-not $v) {
              throw 'VERIFY FAIL click: value still empty after click'
            }
          }
        }
        'press' {
          Guard-Front $tpid
          $el = Walk-UIA $tpid $act.text $act.role $(if ($act.nth) { [int]$act.nth } else { 0 })
          if (-not $el) { throw "press: no element «$($act.text)»" }
          $how = Invoke-Element $el[0]
          if (-not $how) {
            $ctr = Get-ElCenter $el[0]
            if (-not $ctr) { throw 'press: no action pattern and no position' }
            Send-Mouse $ctr[0] $ctr[1] -click
            $how='hid-click'
          }
          Start-Sleep -Milliseconds 400
          $nm=$el[1]; if ($nm) { $nm=$nm.Substring(0,[Math]::Min(30,$nm.Length)) } else { $nm='?' }
          $msg="OK confirmed ${idx}press «$nm» ($how)"; $c++
        }
        'set' {
          $el = Walk-UIA $tpid $act.text $act.role $(if ($act.nth) { [int]$act.nth } else { 0 })
          if (-not $el) { throw "set: no element «$($act.text)»" }
          if (-not (Set-ElementValue $el[0] $act.value)) {
            $ctr = Get-ElCenter $el[0]
            if (-not $ctr) { throw 'set: not editable and no position' }
            Guard-Front $tpid
            Send-Mouse $ctr[0] $ctr[1] -click
            Start-Sleep -Milliseconds 200
            Send-Key 'ctrl+a'
            Send-Text $act.value
          }
          Start-Sleep -Milliseconds 200
          $el2 = Walk-UIA $tpid $act.text $act.role 0
          $v=''; if ($el2) { $v=$el2[2] }
          if ($act.value -and $v -and -not $v.Contains($act.value)) {
            throw "VERIFY FAIL set: wrote «$($act.value)» read back «$v»"
          }
          $vv=$act.value; if ($vv) { $vv=$vv.Substring(0,[Math]::Min(40,$vv.Length)) }
          $msg="OK confirmed ${idx}set v=«$vv»"; $c++
        }
        'focus' {
          $el = Walk-UIA $tpid $act.text $act.role $(if ($act.nth) { [int]$act.nth } else { 0 })
          if (-not $el) { throw "focus: no element «$($act.text)»" }
          try { $el[0].SetFocus() } catch {
            $ctr = Get-ElCenter $el[0]
            if ($ctr) { Guard-Front $tpid; Send-Mouse $ctr[0] $ctr[1] -click }
          }
          $nm=$el[1]; if ($nm) { $nm=$nm.Substring(0,[Math]::Min(30,$nm.Length)) } else { $nm='?' }
          $msg="OK confirmed ${idx}focus «$nm»"; $c++
        }
        'type' {
          Guard-Front $tpid
          Send-Text $act.text
          $msg="OK delivered ${idx}type len=$($act.text.Length)"; $u++
        }
        'key' {
          Guard-Front $tpid
          Send-Key $act.spec
          $msg="OK delivered ${idx}key $($act.spec)"; $u++
        }
        'wait' { Start-Sleep -Milliseconds ([int]$act.ms); $msg="OK ${idx}wait $($act.ms)"; $u++ }
        'remember' {
          if (-not $act.x -or -not $act.y) { throw 'remember need x,y' }
          $ck=Load-Cache; $key=Cache-Key $act $tpid
          $ck | Add-Member -MemberType NoteProperty -Name $key -Value @{x=[int]$act.x; y=[int]$act.y} -Force
          Save-Cache $ck
          $msg="OK confirmed ${idx}remember key=$key -> ($($act.x),$($act.y)) saved"; $c++
        }
        'recall' {
          $key=Cache-Key $act $tpid
          $ck=Load-Cache
          $entry=$ck.$key
          if (-not $entry) { throw "RECALL MISS key=$key — remember it first" }
          $msg="OK confirmed ${idx}recall $key -> ($($entry.x),$($entry.y))"; $c++
        }
        'dropdown' {
          Guard-Front $tpid
          if ($act.ocr) {
            $hits=Get-OcrMatches $tpid $act.ocr
            if ($hits.Count -eq 0) { throw "OCR MISS «$($act.ocr)»" }
            $fx=$hits[0][1]; $fy=$hits[0][2]
          } elseif ($act.key) {
            $key=Cache-Key $act $tpid; $entry=(Load-Cache).$key
            if (-not $entry) { throw "RECALL MISS key=$key" }
            $fx=$entry.x; $fy=$entry.y
          } else { $fx=[int]$act.x; $fy=[int]$act.y }
          Send-Mouse $fx $fy -click
          Start-Sleep -Milliseconds $(if ($act.settle) { [int]$act.settle } else { 700 })
          if ($act.search) {
            Send-Text $act.search
            Start-Sleep -Milliseconds $(if ($act.settle) { [int]$act.settle } else { 900 })
          }
          if (-not $act.pick) { throw 'dropdown needs pick=' }
          $hits=Get-OcrMatches $tpid $act.pick
          if ($hits.Count -eq 0) { throw "OCR MISS option «$($act.pick)» — list may not contain it" }
          # shortest hit = closest label match
          $best=$hits[0]; foreach ($h in $hits) { if ($h[0].Length -lt $best[0].Length) { $best=$h } }
          Send-Mouse $best[1] $best[2] -click
          $pt=$best[0]; if ($pt.Length -gt 30) { $pt=$pt.Substring(0,30) }
          $msg="OK confirmed ${idx}dropdown pick «$pt»@($($best[1]),$($best[2]))"; $c++
          if ($act.verify) {
            Start-Sleep -Milliseconds $(if ($act.verify.wait) { [int]$act.verify.wait } else { 800 })
            $v = Read-VerifyValue $act.verify $tpid
            if ($act.verify.contains -and (-not $v -or -not $v.ToLower().Contains($act.verify.contains.ToLower()))) {
              throw "VERIFY FAIL dropdown: got v=«$v» expected contains «$($act.verify.contains)»"
            }
            $msg += " verified v=«$v»"
          }
        }
        'read_errors' {
          $script:ERRS=@()
          $roots = Get-AppRoots $tpid
          function Scan($el,[int]$d) {
            if ($d -gt 22 -or $script:ERRS.Count -ge 5) { return }
            try {
              $role=$el.Current.ControlType.ProgrammaticName -replace '^ControlType\.',''
              $val=''
              try { $val=$el.Current.ValuePattern.Current.Value } catch {}
              if (-not $val) { try { $val=$el.Current.Name } catch {} }
              if ($val -and ($role -eq 'Text' -or $role -eq 'Alert')) {
                foreach ($p in $script:ERR_PATS) {
                  if ($val.ToLower().Contains($p.ToLower())) { $script:ERRS+=$val.Substring(0,[Math]::Min(60,$val.Length)); break }
                }
              }
              $kids=$el.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
              foreach ($k in $kids) { Scan $k ($d+1) }
            } catch {}
          }
          foreach ($w in $roots) { Scan $w 0 }
          if ($script:ERRS.Count -eq 0) { $msg="OK ${idx}read_errors none"; $u++ }
          else { throw "FORM_ERROR detected: $($script:ERRS -join ' | ') — fix fields before re-submitting" }
        }
        'scroll' {
          # CLI contract: dy>0 = scroll down (macOS engine posts wheel1=-dy)
          Guard-Front $tpid
          $dy=-3
          if ($act.dy) { $dy=[int]$act.dy }
          $delta = -$dy                       # Windows: negative delta = scroll down
          $md = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]($delta * 0x10000)), 0)
          $i=[AxWin.Native+INPUT[]]::new(1)
          $i[0].type=0; $i[0].u.mi.mouseData=$md; $i[0].u.mi.dwFlags=0x0800  # MOUSEEVENTF_WHEEL
          [AxWin.Native]::SendInput(1,$i,[Runtime.InteropServices.Marshal]::SizeOf([type][AxWin.Native+INPUT])) | Out-Null
          Start-Sleep -Milliseconds 200
          $msg="OK delivered ${idx}scroll dy=$dy (dx unsupported on Windows engine)"; $u++
        }
        default { throw "unknown op '$op' (click/press/set/focus/type/key/wait/scroll/remember/recall/dropdown/read_errors)" }
      }
    } catch {
      $e++; $msg="ERR [$idx] ${op}: $($_.Exception.Message)"
      if ($script:FRONT_WARN) { $msg += $script:FRONT_WARN; $script:FRONT_WARN='' }
      $abort="ABORTED at action[$idx] op=$op"
      Write-Output $msg; break
    }
    if ($script:FRONT_WARN) { $msg += $script:FRONT_WARN; $script:FRONT_WARN='' }
    Write-Output $msg
    $idx++
  }
  $focusAfter = Get-FrontPid
  $sum = "SUMMARY confirmed=$c unverified=$u suspected_noop=$n errors=$e"
  if ($abort) { $sum += " $abort" }
  Write-Output $sum
  if ($focusBefore -ne $focusAfter) { Write-Output "FOCUS pid $focusBefore -> $focusAfter" }
}

# ---- dispatch ----
$a = Parse-Args $args
$sub = $args[0]
switch ($sub) {
  'winlist'  { Cmd-Winlist $a }
  'axtree'   { Cmd-Axtree $a }
  'axread'   { Cmd-Axread $a }
  'shot'     { Cmd-Shot $a }
  'ocr'      { Cmd-Ocr $a }
  'axact'    { Cmd-Axact $a }
  'relaunch' { Cmd-Relaunch $a }
  default    { Write-Output 'axc (Windows engine v2 P1+P2) — winlist|axtree|axread|axact|shot|ocr|relaunch' }
}
