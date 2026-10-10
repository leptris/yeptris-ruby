# win-hang-dump.ps1 - #504: minidump of a hung ruby process (thread
# stacks + module list; dbghelp needs no downloads on hosted runners).
param(
  [Parameter(Mandatory = $true)][int]$ProcId,
  [Parameter(Mandatory = $true)][string]$Out
)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MiniDump {
  [DllImport("dbghelp.dll", SetLastError = true)]
  public static extern bool MiniDumpWriteDump(IntPtr hProcess, uint ProcessId, IntPtr hFile, uint DumpType, IntPtr ExceptionParam, IntPtr UserStreamParam, IntPtr CallbackParam);
}
"@
$p = Get-Process -Id $ProcId -ErrorAction Stop
$fs = [System.IO.File]::Create($Out)
try {
  $ok = [MiniDump]::MiniDumpWriteDump($p.Handle, [uint32]$ProcId, $fs.SafeFileHandle.DangerousGetHandle(), 0x0, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
  if (-not $ok) {
    Write-Output ("dump-failed gle=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
  } else {
    Write-Output ("dump-written " + $Out)
  }
} finally {
  $fs.Close()
}
