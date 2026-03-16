# Redguard Windowed Launcher
# Launches DOSBox SVN-Daum with Redguard, injects D3D9 hook to force windowed Glide rendering.
# Requires: redguard_hook.dll in the same directory as this script.

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hookDll = Join-Path $scriptDir "redguard_hook.dll"
$dosboxDir = "D:\Games\GOG Galaxy\Redguard\DOSBOX"
$dosboxExe = Join-Path $dosboxDir "dosbox.exe"
$conf1 = "D:\Games\GOG Galaxy\Redguard\dosbox_redguard.conf"
$conf2 = "D:\Games\GOG Galaxy\Redguard\dosbox_redguard_single.conf"

if (-not (Test-Path $hookDll)) {
    Write-Host "ERROR: redguard_hook.dll not found at $hookDll" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $dosboxExe)) {
    Write-Host "ERROR: dosbox.exe not found at $dosboxExe" -ForegroundColor Red
    exit 1
}

# --- Win32 P/Invoke for DLL injection ---
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Win32 {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr VirtualAllocEx(IntPtr hProc, IntPtr addr, uint size, uint type, uint protect);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteProcessMemory(IntPtr hProc, IntPtr addr, byte[] buf, uint size, out int written);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetModuleHandle(string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr hMod, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateRemoteThread(IntPtr hProc, IntPtr attr, uint stack, IntPtr start, IntPtr param, uint flags, out int tid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint ms);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualFreeEx(IntPtr hProc, IntPtr addr, uint size, uint type);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string cls, string wnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowThreadProcessId(IntPtr hwnd, out int pid);

    public const uint PROCESS_ALL_ACCESS = 0x001F0FFF;
    public const uint MEM_COMMIT = 0x1000;
    public const uint MEM_RESERVE = 0x2000;
    public const uint MEM_RELEASE = 0x8000;
    public const uint PAGE_READWRITE = 0x04;
}
"@

# --- Launch DOSBox ---
Write-Host "Launching DOSBox..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $dosboxExe -ArgumentList "-conf `"$conf1`" -conf `"$conf2`" -noconsole" -WorkingDirectory $dosboxDir -PassThru

# --- Wait for SDL window ---
Write-Host "Waiting for SDL window..." -ForegroundColor Cyan
$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 60; $i++) {
    $hwnd = [Win32]::FindWindow("SDL_app", $null)
    if ($hwnd -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 500
}
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Host "ERROR: SDL window not found after 30s" -ForegroundColor Red
    exit 1
}

# --- Get PID ---
$pid = 0
[void][Win32]::GetWindowThreadProcessId($hwnd, [ref]$pid)
Write-Host "DOSBox PID: $pid" -ForegroundColor Green

# --- Inject hook DLL ---
Write-Host "Injecting hook DLL..." -ForegroundColor Cyan

$dllBytes = [System.Text.Encoding]::ASCII.GetBytes($hookDll + "`0")
$hProc = [Win32]::OpenProcess([Win32]::PROCESS_ALL_ACCESS, $false, $pid)
if ($hProc -eq [IntPtr]::Zero) {
    Write-Host "ERROR: OpenProcess failed" -ForegroundColor Red
    exit 1
}

$remoteMem = [Win32]::VirtualAllocEx($hProc, [IntPtr]::Zero, [uint]$dllBytes.Length, [Win32]::MEM_COMMIT -bor [Win32]::MEM_RESERVE, [Win32]::PAGE_READWRITE)
if ($remoteMem -eq [IntPtr]::Zero) {
    Write-Host "ERROR: VirtualAllocEx failed" -ForegroundColor Red
    [void][Win32]::CloseHandle($hProc)
    exit 1
}

$written = 0
[void][Win32]::WriteProcessMemory($hProc, $remoteMem, $dllBytes, [uint]$dllBytes.Length, [ref]$written)

$kernel32 = [Win32]::GetModuleHandle("kernel32.dll")
$loadLib = [Win32]::GetProcAddress($kernel32, "LoadLibraryA")

$tid = 0
$hThread = [Win32]::CreateRemoteThread($hProc, [IntPtr]::Zero, 0, $loadLib, $remoteMem, 0, [ref]$tid)
if ($hThread -eq [IntPtr]::Zero) {
    Write-Host "ERROR: CreateRemoteThread failed" -ForegroundColor Red
    [void][Win32]::VirtualFreeEx($hProc, $remoteMem, 0, [Win32]::MEM_RELEASE)
    [void][Win32]::CloseHandle($hProc)
    exit 1
}

[void][Win32]::WaitForSingleObject($hThread, 10000)
[void][Win32]::CloseHandle($hThread)
[void][Win32]::VirtualFreeEx($hProc, $remoteMem, 0, [Win32]::MEM_RELEASE)
[void][Win32]::CloseHandle($hProc)

Write-Host "Hook injected! Game will run windowed." -ForegroundColor Green
Write-Host "Waiting for DOSBox to exit..." -ForegroundColor Cyan
$proc.WaitForExit()
