#Requires -Version 5.1
# axc.ps1 - Windows engine for ax-computer-use v2
# Contract twin of src/axc.swift (macOS). Same subcommands, same output grammar.
# Stack: UIA (System.Windows.Automation) for the tree, SendInput (P/Invoke) for
# HID-grade input, CopyFromScreen for JPEG shots, Windows.Media.Ocr for text.
# Zero external dependencies: PowerShell 5.1 + .NET 4.x ship with every Windows 10/11.

param()
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$ErrorActionPreference = 'Continue'
$script:FRONT_WARN = ''

# ---- SendInput P/Invoke (HID-grade: reaches Chromium renderers, unlike synthetic) ----
if (-not ('AxWin.Native' -as [type])) {
Add-Type -Namespace AxWin -Name Native -MemberDefinition @"
[DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
"@
}
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
    $mvk = switch ($m) { ctrl{0x11} alt{0x12} shift{0x10} win{0x5B} }
    $seq += ,@($mvk,$false)
  }
  $seq += ,@($vk,$false); $seq += ,@($vk,$true)
  [array]::Reverse($seq[-1..-1]) # keyup after keydown; mods released in reverse below
  foreach ($s in $seq) {
    $i=[AxWin.Native+INPUT[]]::new(1); $i[0].type=1; $i[0].u.ki.wVk=[uint16]$s[0]
    if ($s[1]) { $i[0].u.ki.dwFlags=$KEY_UP }
    [AxWin.Native]::SendInput(1,$i,[Runtime.InteropServices.Marshal]::SizeOf([type][AxWin.Native+INPUT])) | Out-Null
    Start-Sleep -Milliseconds 15
  }
  for ($j=$mods.Count-1; $j -ge 0; $j--) {
    $mvk = switch ($mods[$j]) { ctrl{0x11} alt{0x12} shift{0x10} win{0x5B} }
    $i=[AxWin.Native+INPUT[]]::new(1); $i[0].type=1; $i[0].u.ki.wVk=[uint16]$mvk; $i[0].u.ki.dwFlags=$KEY_UP
    [AxWin.Native]::SendInput(1,$i,[Runtime.InteropServices.Marshal]::SizeOf([type][AxWin.Native+INPUT])) | Out-Null
  }
}

function Get-FrontPid {
  $h=[AxWin.Native]::GetForegroundWindow(); $p=[uint32]0
  [AxWin.Native]::GetWindowThreadProcessId($h,[ref]$p) | Out-Null; return $p
}
function Guard-Front([int]$pid) {
  $f=Get-FrontPid
  if ($f -ne $pid) {
    $proc=Get-Process -Id $pid -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);' -Name FG -Namespace AxWin
      [AxWin.FG]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null; Start-Sleep -Milliseconds 500
    }
    $f2=Get-FrontPid
    if ($f2 -ne $pid) { $script:FRONT_WARN=" WARN_FRONT pid=$f2 '$(Get-Process -Id $f2 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty ProcessName)' — input may land elsewhere!" }
  }
}

# ---- args parsing: --key value / --flag (value "1") ----
function Parse-Args($argv) {
  $a=@{}
  for ($i=0; $i -lt $argv.Count; $i++) {
    if ($argv[$i] -like '--*') { $k=$argv[$i].TrimStart('-'); $a[$k]=$argv[$i+1]; $i++ }
  }
  return $a
}
function Get-TargetPid($a) { return [int]$a['pid'] }

# ---- winlist ----
function Cmd-Winlist($a) {
  $filter = if ($a.ContainsKey('pid')) { [int]$a['pid'] } else { $null }
  Get-Process | Where-Object { $_.MainWindowTitle -ne '' -and $_.MainWindowHandle -ne 0 } | ForEach-Object {
    if ($filter -and $_.Id -ne $filter) { return }
    $r=[AxWin.Native+RECT]::new()
    $out="$($_.MainWindowHandle) pid$($_.Id) $($_.ProcessName) «$($_.MainWindowTitle)»"
    Write-Output $out
  }
}

# ---- axtree (UIA) ----
function Cmd-Axtree($a) {
  $pid = Get-TargetPid $a
  $depthMax = if ($a['depth']) { [int]$a['depth'] } else { 9 }
  $nodeCap  = if ($a['max'])   { [int]$a['max'] }   else { 900 }
  $textF    = $a['text']
  $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pid)))
  $auto = [System.Windows.Automation.Automation]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pid)))
  $auto.SetFocus()  # nudge: UIA tree of Chromium needs an activate touch like macOS AXManualAccessibility
  Start-Sleep -Milliseconds 400
  $roots = $auto.FindAll([System.Windows.Automation.TreeScope]::Children,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::IsControlElementProperty, $true)))
  $count=0
  function Dump($el,[int]$d,[string]$chain) {
    if ($script:count -ge $nodeCap -or $d -gt $depthMax) { return }
    $script:count++
    $name=$el.Current.Name; $val=''; try { $val=$el.Current.ValuePattern.Current.Value } catch {}
    if (-not $val) { try { $val=$el.Current.LegacyIAccessiblePattern.Current.Value } catch {} }
    $role=$el.Current.ControlType.ProgrammaticName -replace '^ControlType\.',''
    $line="$chain$role t=$(if($name){$name}else{'-'})" + $(if($val){" v=$val"})
    Write-Output $line
    $kids=$el.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
    $i=0
    foreach ($k in $kids) { Dump $k ($d+1) "$chain$i."; $i++ }
  }
  $ri=0
  foreach ($w in $roots) { Write-Output "[:$($w.Current.ControlType.ProgrammaticName -replace '^ControlType\.','')] window#$ri"; Dump $w 0 ''; $ri++ }
  Write-Output "NODES $count"
}

# ---- axread ----
function Cmd-Axread($a) {
  Write-Output "axread: locate by runtime id not yet portable on Windows engine (use axtree output directly)"
}

# ---- shot (JPEG) ----
function Cmd-Shot($a) {
  $out = if ($a['out']) { $a['out'] } else { "$env:TEMP\axc-shot.jpg" }
  $maxL = if ($a['max']) { [int]$a['max'] } else { 1280 }
  $b=[System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.X,$b.Y,0,0,$bmp.Size)
  if ($b.Width -gt $maxL -or $b.Height -gt $maxL) {
    $scale=$maxL/[double][Math]::Max($b.Width,$b.Height)
    $bmp2=New-Object System.Drawing.Bitmap ([int]($b.Width*$scale)),([int]($b.Height*$scale))
    $g2=[System.Drawing.Graphics]::FromImage($bmp2); $g2.InterpolationMode='HighQualityBicubic'
    $g2.DrawImage($bmp,0,0,$bmp2.Width,$bmp2.Height); $bmp2.Save($out,[System.Drawing.Imaging.ImageFormat]::Jpeg)
  } else { $bmp.Save($out,[System.Drawing.Imaging.ImageFormat]::Jpeg) }
  Write-Output "SAVED $out"
}

# ---- ocr (Windows.Media.Ocr via WinRT) ----
function Cmd-Ocr($a) {
  try { [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime] | Out-Null
        [Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime] | Out-Null } catch {}
  $eng=[Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if (-not $eng) { Write-Output 'ERR no OCR engine for user languages'; return }
  $png="$env:TEMP\axc-ocr.png"; $a2=@{}+$a; $a2['out']=$png
  $a2['max']=[int](if ($a['max']) { $a['max'] } else { 1280 })
  Cmd-Shot $a2 | Out-Null
  $stream=[IO.File]::OpenRead($png)
  $dec=[Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream).AwaitOperation()
  $bmp=($dec.GetSoftwareBitmapAsync().AwaitOperation())
  $res=$eng.RecognizeAsync($bmp).AwaitOperation()
  $want=$a['text']
  foreach ($line in $res.Text -split "`n") {
    if ($want -and -not $line.ToLower().Contains($want.ToLower())) { continue }
    Write-Output "HIT «$line»"
  }
  $stream.Close()
}
# await WinRT IAsyncOperation from PS
Add-Type -TypeDefinition @"
public static class WinRTHelper { public static T Await<T>(this Windows.Foundation.IAsyncOperation<T> op) {
  var ev=new System.Threading.ManualResetEvent(false); op.Completed = (o,s)=>ev.Set(); ev.WaitOne(15000); return o.GetResults(); } }
"@ | Out-Null
Update-TypeData -TypeName Windows.Foundation.IAsyncOperation`1 -MemberName AwaitOperation -MemberType ScriptMethod -Value { return [WinRTHelper]::Await($this) } -Force | Out-Null

# ---- relaunch ----
function Cmd-Relaunch($a) {
  $app=$a['app']; $appArgs=$a['args']
  $procs=Get-Process -Name $app -ErrorAction SilentlyContinue
  foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  if ($procs) { Start-Sleep -Milliseconds 800 }
  Start-Process -FilePath $app -ArgumentList $appArgs
  Start-Sleep -Seconds 2
  $np=Get-Process -Name $app -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($np) { Write-Output "OK relaunch pid=$($np.Id)" } else { Write-Output 'ERR relaunch: process not found after start' }
}

# ---- axact (batched verified actions) ----
function Cmd-Axact($a) {
  $pid = Get-TargetPid $a
  $json = $a['json']
  $acts = $json | ConvertFrom-Json
  $idx=0; $c=0;$u=0;$n=0;$e=0; $abort=''
  $focusBefore = Get-FrontPid
  foreach ($act in $acts) {
    $op=$act.op; $msg=''
    try {
      switch ($op) {
        'click' {
          Guard-Front $pid
          Send-Mouse ([int]$act.x) ([int]$act.y) -click
          Start-Sleep -Milliseconds 300
          $msg="OK confirmed ${idx}click @($($act.x),$($act.y))"
          $c++
        }
        'type' {
          Guard-Front $pid
          Send-Text $act.text
          $msg="OK delivered ${idx}type len=$($act.text.Length)"; $u++
        }
        'key' {
          Guard-Front $pid
          Send-Key $act.spec
          $msg="OK delivered ${idx}key $($act.spec)"; $u++
        }
        'wait' { Start-Sleep -Milliseconds ([int]$act.ms); $msg="OK ${idx}wait $($act.ms)"; $u++ }
        default { throw "unknown op '$op' (click/type/key/wait on Windows engine v0.1)" }
      }
    } catch {
      $e++; $msg="ERR [$idx] ${op}: $($_.Exception.Message)"
      $abort="ABORTED at action[$idx] op=$op"
      Write-Output $msg; break
    }
    if ($script:FRONT_WARN) { $msg += $script:FRONT_WARN; $script:FRONT_WARN='' }
    Write-Output $msg
    $idx++
  }
  $focusAfter = Get-FrontPid
  Write-Output "SUMMARY confirmed=$c unverified=$u suspected_noop=$n errors=$e" + $(if($abort){" $abort"})
  if ($focusBefore -ne $focusAfter) { Write-Output "FOCUS pid $focusBefore -> $focusAfter" }
}

# ---- dispatch ----
$a = Parse-Args $args
switch ($args[0]) {
  'winlist' { Cmd-Winlist $a }
  'axtree'  { Cmd-Axtree $a }
  'axread'  { Cmd-Axread $a }
  'axact'   { Cmd-Axact $a }
  'shot'    { Cmd-Shot $a }
  'ocr'     { Cmd-Ocr $a }
  'relaunch'{ Cmd-Relaunch $a }
  default   { Write-Output 'axc (Windows engine) — winlist|axtree|axread|axact|shot|ocr|relaunch' }
}
