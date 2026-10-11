# win-hang-dump.ps1 - #504: minidump of the hung ruby descendants
# (thread stacks + module list; dbghelp needs no downloads on hosted
# runners). -ProcId is the watchdog's direct child, which on windows
# is a cmd.exe wrapper - the hung ruby lives BELOW it, so every
# ruby.exe descendant of the tree gets its own dump.
param(
  [Parameter(Mandatory = $true)][int]$ProcId,
  [Parameter(Mandatory = $true)][string]$OutPrefix
)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MiniDump {
  [DllImport("dbghelp.dll", SetLastError = true)]
  public static extern bool MiniDumpWriteDump(IntPtr hProcess, uint ProcessId, IntPtr hFile, uint DumpType, IntPtr ExceptionParam, IntPtr UserStreamParam, IntPtr CallbackParam);
}
"@
function Write-Dump([int]$TargetId, [string]$Path) {
  $p = Get-Process -Id $TargetId -ErrorAction SilentlyContinue
  if ($null -eq $p) { return }
  $fs = [System.IO.File]::Create($Path)
  try {
    $ok = [MiniDump]::MiniDumpWriteDump($p.Handle, [uint32]$TargetId, $fs.SafeFileHandle.DangerousGetHandle(), 0x0, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    if (-not $ok) {
      Write-Output ("dump-failed pid=" + $TargetId + " gle=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    } else {
      Write-Output ("dump-written pid=" + $TargetId + " " + $Path)
    }
  } finally {
    $fs.Close()
  }
}
$seen = @{}
$frontier = @($ProcId)
while ($frontier.Count -gt 0) {
  $next = @()
  foreach ($pid_ in $frontier) {
    if ($seen.ContainsKey($pid_)) { continue }
    $seen[$pid_] = 1
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$pid_" -ErrorAction SilentlyContinue
    if ($null -eq $proc) { continue }
    if ($proc.Name -eq "ruby.exe") {
      Write-Dump $pid_ ($OutPrefix + "-" + $pid_ + ".dmp")
    }
    $next += @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$pid_" -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessId })
  }
  $frontier = $next
}
Write-Output "tree-walk-done"
