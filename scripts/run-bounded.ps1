# Run a PowerShell script with a hard time limit and memory cap; kills the whole process tree on breach.
# Exit: the script's own code, 124 = timeout, 125 = memory cap. Use for every test run and agent run.
# Usage: pwsh -File run-bounded.ps1 -Script tests/Test-X.ps1 [-TimeoutSeconds 600] [-MaxMB 3000] [-ScriptArgs ...]
# Containment is a Windows Job Object, not a parent-PID walk: every descendant (even one whose parent already exited,
# like kitchen workers started by a short-lived tick) inherits the job, the memory cap counts the whole tree's commit,
# and closing the job handle (normal exit, timeout, cap, or this script dying) kills anything still running.
# -CommandFile: a JSON file {exe, args} to run instead of `pwsh -File <Script>` (the tests station hands it kitchen-sandbox.exe, so a
# sandboxed suite is measured too: the sandbox's own job nests inside this one). -Script then only names the suite in messages and records.
# -TimesFile: append one line per run, {repo, suite, sec, cpuSec, procs, peakMB, ok, code, parallel, sha, at}, read from the job's own
# accounting (the whole tree). The tests station reads it back for its memory budget, order and per-suite limits (kitchen/suite-times-lib.ps1).
# The C# type is compiled once into TEMP\brain-bounded\BoundedJob-<hash of its source>.dll and loaded from there by every later run
# (compiling it in every new pwsh cost ~0.5 s per suite); an unwritable or broken cache falls back to compiling in memory.
param([Parameter(Mandatory)][string]$Script, [int]$TimeoutSeconds = 600, [int]$MaxMB = 3000, [string[]]$ScriptArgs = @(),
    [string]$CommandFile = '', [string]$TimesFile = '', [string]$Repo = '', [string]$Suite = '', [int]$Parallel = 1, [string]$Sha = '')
$ErrorActionPreference = 'Stop'
$src = @'
using System; using System.Runtime.InteropServices;
public static class BoundedJob {
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct IOC { public ulong a, b, c, d, e, f; }
  [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IOC Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
  [StructLayout(LayoutKind.Sequential)] struct ACCT { public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime; public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr j, int c, ref EXT i, uint l);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr j, int c, out EXT i, uint l, IntPtr r);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr j, int c, out ACCT i, uint l, IntPtr r);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr j, uint code);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] struct PORT { public IntPtr Key, Port; }
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr j, int c, ref PORT i, uint l);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateIoCompletionPort(IntPtr f, IntPtr e, UIntPtr k, uint n);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetQueuedCompletionStatus(IntPtr p, out uint msg, out UIntPtr k, out IntPtr o, uint ms);
  static IntPtr port = IntPtr.Zero;
  // True once the OS refused an allocation because the job hit its memory limit (JOB_OBJECT_MSG_JOB_MEMORY_LIMIT = 10).
  public static bool HitMemoryLimit() { if (port == IntPtr.Zero) return false; uint m; UIntPtr k; IntPtr o;
    while (GetQueuedCompletionStatus(port, out m, out k, out o, 0)) { if (m == 10 || m == 9) return true; } return false; }
  public static IntPtr Create(ulong memBytes) {
    IntPtr j = CreateJobObject(IntPtr.Zero, null); if (j == IntPtr.Zero) throw new Exception("CreateJobObject failed: " + Marshal.GetLastWin32Error());
    EXT e = new EXT(); e.Basic.LimitFlags = 0x2000 | 0x200; e.JobMemoryLimit = new UIntPtr(memBytes); // KILL_ON_JOB_CLOSE | JOB_MEMORY
    if (!SetInformationJobObject(j, 9, ref e, (uint)Marshal.SizeOf(typeof(EXT)))) { int err = Marshal.GetLastWin32Error(); CloseHandle(j); throw new Exception("SetInformationJobObject failed: " + err); }
    port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
    if (port != IntPtr.Zero) { PORT pi = new PORT(); pi.Key = j; pi.Port = port; SetInformationJobObject(j, 7, ref pi, (uint)Marshal.SizeOf(typeof(PORT))); }
    return j; }
  public static void Assign(IntPtr j, IntPtr p) { if (!AssignProcessToJobObject(j, p)) throw new Exception("AssignProcessToJobObject failed: " + Marshal.GetLastWin32Error()); }
  public static ulong PeakBytes(IntPtr j) { EXT e; return QueryInformationJobObject(j, 9, out e, (uint)Marshal.SizeOf(typeof(EXT)), IntPtr.Zero) ? e.PeakJobMemoryUsed.ToUInt64() : 0; }
  // JobObjectBasicAccountingInformation (class 1): user + kernel CPU of every process the job ever held (100 ns units), and how many
  public static double CpuSeconds(IntPtr j) { ACCT a; return QueryInformationJobObject(j, 1, out a, (uint)Marshal.SizeOf(typeof(ACCT)), IntPtr.Zero) ? (a.TotalUserTime + a.TotalKernelTime) / 1e7 : -1; }
  public static long Processes(IntPtr j) { ACCT a; return QueryInformationJobObject(j, 1, out a, (uint)Marshal.SizeOf(typeof(ACCT)), IntPtr.Zero) ? a.TotalProcesses : -1; }
  // kitchen-sandbox.exe starts the suite in a job of its own, and that suite is not counted here (measured: this job's peak 2 MB, CPU 0 s,
  // process list = the sandbox exe only, for a 300 MB suite). Sample(root) walks the process tree under the given process (a Toolhelp
  // snapshot, a few ms), adds up private bytes and keeps the highest total, and remembers each process's last CPU time. Run every poll,
  // so it is a 0.5 s sample: a floor, not the exact peak the job gives for an unsandboxed run.
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct PE32 { public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile; }
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr s, ref PE32 e);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr s, ref PE32 e);
  static ulong sampledPeak = 0; static System.Collections.Generic.Dictionary<string, double> cpu = new System.Collections.Generic.Dictionary<string, double>();
  // pid -> start time: Windows reuses pids, so a member is the pid AND the start time it had when it joined (a first version keyed on
  // the pid alone counted unrelated processes that got a dead member's pid: 10 GB "peaks" over a 40-minute run)
  static System.Collections.Generic.Dictionary<int, DateTime> tree = new System.Collections.Generic.Dictionary<int, DateTime>();
  static DateTime Started(int pid) { try { using (var p = System.Diagnostics.Process.GetProcessById(pid)) { return p.StartTime; } } catch { return DateTime.MinValue; } }
  public static void Sample(int root) {
    if (tree.Count == 0) { DateTime rs = Started(root); if (rs == DateTime.MinValue) return; tree[root] = rs; }
    IntPtr s = CreateToolhelp32Snapshot(2, 0); if (s == new IntPtr(-1)) return;
    var kids = new System.Collections.Generic.List<int[]>();
    try { PE32 e = new PE32(); e.dwSize = (uint)Marshal.SizeOf(typeof(PE32)); if (Process32FirstW(s, ref e)) { do { kids.Add(new int[] { (int)e.th32ProcessID, (int)e.th32ParentProcessID }); } while (Process32NextW(s, ref e)); } }
    finally { CloseHandle(s); }
    var alive = new System.Collections.Generic.Dictionary<int, DateTime>();
    foreach (int[] k in kids) { if (tree.ContainsKey(k[0])) { DateTime st = Started(k[0]); if (st == tree[k[0]]) alive[k[0]] = st; } }
    // a process joins when its parent is a live member that started before it; it stays a member after that parent exits
    bool grew = true; while (grew) { grew = false; foreach (int[] k in kids) {
      if (alive.ContainsKey(k[0]) || !alive.ContainsKey(k[1])) continue;
      DateTime st = Started(k[0]); if (st == DateTime.MinValue || st < alive[k[1]]) continue;
      tree[k[0]] = st; alive[k[0]] = st; grew = true; } }
    ulong sum = 0;
    foreach (int pid in alive.Keys) {
      try { using (var p = System.Diagnostics.Process.GetProcessById(pid)) { if (p.StartTime != alive[pid]) continue; sum += (ulong)p.PrivateMemorySize64; cpu[pid + "@" + alive[pid].Ticks] = p.TotalProcessorTime.TotalSeconds; } } catch { } }
    if (sum > sampledPeak) sampledPeak = sum;
  }
  public static ulong SampledPeakBytes() { return sampledPeak; }
  public static int SampledProcesses() { return tree.Count; }
  public static double SampledCpuSeconds() { double s = 0; foreach (double v in cpu.Values) s += v; return s; }
  public static void Kill(IntPtr j, uint code) { TerminateJobObject(j, code); }
}
'@
if (-not ('BoundedJob' -as [type])) {
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($src))).Substring(0, 16)
    $cache = Join-Path ([IO.Path]::GetTempPath()) 'brain-bounded'; $dll = Join-Path $cache "BoundedJob-$hash.dll"
    try {
        if (-not (Test-Path -LiteralPath $dll)) {
            # built under a unique name, then moved into place: two suites starting at once never load a half-written file
            New-Item -ItemType Directory -Force -Path $cache | Out-Null
            $tmp = Join-Path $cache ('build-' + [guid]::NewGuid().ToString('N') + '.dll')
            Add-Type -TypeDefinition $src -OutputAssembly $tmp
            try { Move-Item -LiteralPath $tmp -Destination $dll -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
        [void][Reflection.Assembly]::LoadFrom($dll)   # ~40 ms less than Add-Type -Path
    } catch { }
    if (-not ('BoundedJob' -as [type])) { Add-Type -TypeDefinition $src }
}
$psi = [Diagnostics.ProcessStartInfo]::new(); $psi.UseShellExecute = $false
if ($CommandFile) {
    $cmd = Get-Content -LiteralPath $CommandFile -Raw | ConvertFrom-Json
    $psi.FileName = [string]$cmd.exe; foreach ($a in @($cmd.args)) { $psi.ArgumentList.Add([string]$a) }
} else {
    $psi.FileName = [Environment]::ProcessPath
    foreach ($a in @('-NoProfile', '-File', $Script) + $ScriptArgs) { $psi.ArgumentList.Add([string]$a) }
}
$capBytes = [uint64]$MaxMB * 1MB
# Two layers: we poll the job's peak commit (all descendants together) and kill at the cap with 125; the OS also holds
# a hard wall at 1.5x the cap, because a single huge allocation can outrun a 500 ms poll (it then fails with out-of-memory
# instead of swapping the PC). Windows posts no notice when a commit merely fails against the wall, so the wall is the backstop.
$job = [BoundedJob]::Create([uint64]($capBytes * 1.5))
$code = $null
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $p = [Diagnostics.Process]::Start($psi)
    # Assigned right after start: pwsh needs far longer than this to load before the script can spawn anything.
    # If assignment fails we fail CLOSED (kill the child) rather than run it uncontained.
    try { [BoundedJob]::Assign($job, $p.Handle) } catch { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null; Write-Host "run-bounded: could not contain $Script ($($_.Exception.Message)); not run"; exit 126 }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    # WaitForExit(500) returns the moment the child ends (a fixed 500 ms sleep added up to half a second to every suite)
    while (-not $p.WaitForExit(500)) {
        if ($CommandFile -and $TimesFile) { [BoundedJob]::Sample($p.Id) }
        if ((Get-Date) -gt $deadline) { $code = 124; break }
        if ([BoundedJob]::HitMemoryLimit() -or [BoundedJob]::PeakBytes($job) -gt $capBytes) { $code = 125; break }
    }
    if ($null -eq $code) { $p.WaitForExit(); if ([BoundedJob]::HitMemoryLimit() -or [BoundedJob]::PeakBytes($job) -gt $capBytes) { $code = 125 } }
    if ($null -ne $code) {
        [BoundedJob]::Kill($job, [uint32]$code)
        # the limit is in the line (TD-EH-16): the tests Step reads it back to say "timed out after N s" / "stopped at the memory cap (N MB)"
        Write-Host ("run-bounded: killed {0} (exit {1}: {2})" -f $Script, $code, $(if ($code -eq 124) { "timeout after $TimeoutSeconds s" } else { "memory cap $MaxMB MB" }))
    } else { $code = $p.ExitCode }
    if ($TimesFile) {
        # one line per run; several suites may finish at once, so a locked file is retried for a moment, then given up (and said)
        $rec = [ordered]@{ repo = $Repo; suite = $(if ($Suite) { $Suite } else { [IO.Path]::GetFileNameWithoutExtension($Script) }); sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            cpuSec = [math]::Round([math]::Max([BoundedJob]::CpuSeconds($job), [BoundedJob]::SampledCpuSeconds()), 1); procs = [math]::Max([BoundedJob]::Processes($job), [BoundedJob]::SampledProcesses())
            peakMB = [math]::Round([math]::Max([BoundedJob]::PeakBytes($job), [BoundedJob]::SampledPeakBytes()) / 1MB); sampled = [bool]$CommandFile
            ok = ($code -eq 0); code = $code; parallel = $Parallel; sha = $Sha; at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress
        $wrote = $false
        for ($t = 0; $t -lt 20 -and -not $wrote; $t++) { try { [IO.File]::AppendAllText($TimesFile, $rec + "`n"); $wrote = $true } catch { Start-Sleep -Milliseconds 50 } }
        if (-not $wrote) { Write-Host "run-bounded: could not record the suite time in $TimesFile" }
    }
} finally { [void][BoundedJob]::CloseHandle($job) }  # KILL_ON_JOB_CLOSE: anything the suite left running dies here
exit $code
