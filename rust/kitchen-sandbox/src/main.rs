// kitchen-sandbox: run one command line contained, for AI-written tests and code (kitchen tests, mutate and verify stations).
//
//   kitchen-sandbox [--timeout SEC] [--mem MB] [--procs N] [--scratch DIR] [--label-low DIR]... [--cwd DIR] [--path-first DIR]... [--medium] -- PROGRAM [ARGS...]
//
// What it does:
//  1. Job Object: kill-on-job-close (nothing outlives this launcher), whole-tree kill on timeout, a memory cap on the whole tree's
//     committed memory, and an active process cap (no fork bombs). The child starts suspended and joins the job before it runs a
//     single instruction, so it cannot spawn an escapee first.
//  2. Low integrity (S-1-16-4096) via OpenProcessToken + DuplicateTokenEx + SetTokenInformation(TokenIntegrityLevel) +
//     CreateProcessAsUserW: Microsoft's documented low-IL sample, no admin needed. A Low process cannot WRITE to anything labelled
//     Medium (the default for every file Jordan owns): the repos, .git/config and hooks, %LOCALAPPDATA%\brain-kitchen (approvals.md,
//     jobs), the Startup folder, most of HKCU. Task Scheduler registration and WMI process creation are denied too.
//     --medium skips this step (job object and private folders only) for a fallback mode.
//  3. TEMP/TMP/USERPROFILE/HOME/APPDATA/LOCALAPPDATA point into --scratch, which this program labels Low so the child can write there.
//     Git sees no system config and an empty global config (GIT_CONFIG_NOSYSTEM / GIT_CONFIG_GLOBAL), so a planted global or system config is not read. (The repo's own .git/config is still read; Low cannot write it.)
//
// What it CANNOT do (be honest): Low integrity still allows READING Medium files (no-read-up is not set on ordinary files), so a
// sandboxed script can read pass-key.txt or the career folder; and it allows NETWORK access, so it could send what it read. Known
// folders resolved through the registry (not env vars) still point at Jordan's real profile for reads. Closing those needs an
// AppContainer or a separate account (needs Jordan's yes).
//
// Exit: the child's own exit code; 124 = timeout (tree killed); 125 = memory cap hit (tree killed); 126 = the sandbox itself failed
// (bad arguments, could not label, could not start). It never falls back to running the command uncontained.
#![allow(non_snake_case, clippy::upper_case_acronyms)]

use std::ffi::{c_void, OsStr, OsString};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant};

type HANDLE = *mut c_void;
type BOOL = i32;

#[repr(C)]
#[derive(Default)]
struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: u32,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: u32,
    Affinity: usize,
    PriorityClass: u32,
    SchedulingClass: u32,
}
#[repr(C)]
#[derive(Default)]
struct IO_COUNTERS { r: u64, w: u64, o: u64, rb: u64, wb: u64, ob: u64 }
#[repr(C)]
#[derive(Default)]
struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
}
#[repr(C)]
struct JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION {
    IoReadBytesLimit: u64, IoWriteBytesLimit: u64, PerJobUserTimeLimit: i64, JobMemoryLimit: u64,
    RateControlTolerance: i32, RateControlToleranceInterval: i32, LimitFlags: u32,
}
#[repr(C)]
struct JOBOBJECT_ASSOCIATE_COMPLETION_PORT { CompletionKey: *mut c_void, CompletionPort: HANDLE }
#[repr(C)]
struct SID_AND_ATTRIBUTES { Sid: *mut c_void, Attributes: u32 }
#[repr(C)]
struct TOKEN_MANDATORY_LABEL { Label: SID_AND_ATTRIBUTES }
#[repr(C)]
struct STARTUPINFOW {
    cb: u32, lpReserved: *mut u16, lpDesktop: *mut u16, lpTitle: *mut u16,
    dwX: u32, dwY: u32, dwXSize: u32, dwYSize: u32, dwXCountChars: u32, dwYCountChars: u32, dwFillAttribute: u32, dwFlags: u32,
    wShowWindow: u16, cbReserved2: u16, lpReserved2: *mut u8, hStdInput: HANDLE, hStdOutput: HANDLE, hStdError: HANDLE,
}
#[repr(C)]
struct PROCESS_INFORMATION { hProcess: HANDLE, hThread: HANDLE, dwProcessId: u32, dwThreadId: u32 }

#[link(name = "kernel32")]
extern "system" {
    fn CreateJobObjectW(attrs: *const c_void, name: *const u16) -> HANDLE;
    fn SetInformationJobObject(job: HANDLE, class: i32, info: *const c_void, len: u32) -> BOOL;
    fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) -> BOOL;
    fn TerminateJobObject(job: HANDLE, code: u32) -> BOOL;
    fn QueryInformationJobObject(job: HANDLE, class: i32, info: *mut c_void, len: u32, ret: *mut u32) -> BOOL;
    fn CreateIoCompletionPort(file: HANDLE, existing: HANDLE, key: usize, threads: u32) -> HANDLE;
    fn GetQueuedCompletionStatus(port: HANDLE, bytes: *mut u32, key: *mut usize, ov: *mut *mut c_void, ms: u32) -> BOOL;
    fn ResumeThread(thread: HANDLE) -> u32;
    fn TerminateProcess(process: HANDLE, code: u32) -> BOOL;
    fn WaitForSingleObject(h: HANDLE, ms: u32) -> u32;
    fn GetExitCodeProcess(process: HANDLE, code: *mut u32) -> BOOL;
    fn CloseHandle(h: HANDLE) -> BOOL;
    fn GetCurrentProcess() -> HANDLE;
    fn GetStdHandle(which: u32) -> HANDLE;
    fn SetHandleInformation(h: HANDLE, mask: u32, flags: u32) -> BOOL;
    fn LocalFree(p: *mut c_void) -> *mut c_void;
}
#[link(name = "advapi32")]
extern "system" {
    fn OpenProcessToken(process: HANDLE, access: u32, token: *mut HANDLE) -> BOOL;
    fn DuplicateTokenEx(token: HANDLE, access: u32, attrs: *const c_void, level: i32, kind: i32, out: *mut HANDLE) -> BOOL;
    fn SetTokenInformation(token: HANDLE, class: i32, info: *const c_void, len: u32) -> BOOL;
    fn ConvertStringSidToSidW(s: *const u16, sid: *mut *mut c_void) -> BOOL;
    fn GetLengthSid(sid: *mut c_void) -> u32;
    fn CreateProcessAsUserW(token: HANDLE, app: *const u16, cmd: *mut u16, pa: *const c_void, ta: *const c_void, inherit: BOOL,
                            flags: u32, env: *const c_void, cwd: *const u16, si: *const STARTUPINFOW, pi: *mut PROCESS_INFORMATION) -> BOOL;
}

const JOB_OBJECT_LIMIT_ACTIVE_PROCESS: u32 = 0x8;
const JOB_OBJECT_LIMIT_JOB_MEMORY: u32 = 0x200;
const JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION: u32 = 0x400;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
const JOB_EXTENDED_LIMIT_INFORMATION: i32 = 9;
const JOB_ASSOCIATE_COMPLETION_PORT: i32 = 7;
const JOB_NOTIFICATION_LIMIT_INFORMATION: i32 = 12;
const JOB_OBJECT_MSG_NOTIFICATION_LIMIT: u32 = 11;
const JOB_OBJECT_MSG_ACTIVE_PROCESS_LIMIT: u32 = 3;
const JOB_OBJECT_MSG_JOB_MEMORY_LIMIT: u32 = 10;
const TOKEN_ASSIGN_PRIMARY: u32 = 0x1;
const TOKEN_DUPLICATE: u32 = 0x2;
const TOKEN_QUERY: u32 = 0x8;
const TOKEN_ADJUST_DEFAULT: u32 = 0x80;
const MAXIMUM_ALLOWED: u32 = 0x0200_0000;
const SECURITY_IMPERSONATION: i32 = 2;
const TOKEN_PRIMARY: i32 = 1;
const TOKEN_INTEGRITY_LEVEL: i32 = 25;
const SE_GROUP_INTEGRITY: u32 = 0x20;
const CREATE_SUSPENDED: u32 = 0x4;
const CREATE_UNICODE_ENVIRONMENT: u32 = 0x400;
const STARTF_USESTDHANDLES: u32 = 0x100;
const HANDLE_FLAG_INHERIT: u32 = 0x1;
const STD_HANDLES: [u32; 3] = [-10i32 as u32, -11i32 as u32, -12i32 as u32];
const INVALID_HANDLE_VALUE: HANDLE = -1isize as HANDLE;

const EXIT_TIMEOUT: i32 = 124;
const EXIT_MEMORY: i32 = 125;
const EXIT_SANDBOX: i32 = 126;

struct Opts { timeout: u64, mem_mb: u64, procs: u32, scratch: Option<PathBuf>, label_low: Vec<PathBuf>, cwd: Option<PathBuf>, path_first: Vec<OsString>, medium: bool, cmd: Vec<OsString> }

fn fail(msg: &str) -> ! { eprintln!("kitchen-sandbox: {msg}"); std::process::exit(EXIT_SANDBOX) }
fn wide(s: &OsStr) -> Vec<u16> { s.encode_wide().chain(std::iter::once(0)).collect() }
fn last_err() -> String { std::io::Error::last_os_error().to_string() }

fn parse() -> Opts {
    let mut o = Opts { timeout: 600, mem_mb: 4000, procs: 100, scratch: None, label_low: vec![], cwd: None, path_first: vec![], medium: false, cmd: vec![] };
    let mut it = std::env::args_os().skip(1);
    let num = |v: Option<OsString>, name: &str| -> u64 { v.and_then(|s| s.into_string().ok()).and_then(|s| s.parse().ok()).unwrap_or_else(|| fail(&format!("{name} needs a number"))) };
    while let Some(a) = it.next() {
        match a.to_string_lossy().as_ref() {
            "--timeout" => o.timeout = num(it.next(), "--timeout"),
            "--mem" => o.mem_mb = num(it.next(), "--mem"),
            "--procs" => o.procs = num(it.next(), "--procs") as u32,
            "--scratch" => o.scratch = Some(PathBuf::from(it.next().unwrap_or_else(|| fail("--scratch needs a folder")))),
            "--label-low" => o.label_low.push(PathBuf::from(it.next().unwrap_or_else(|| fail("--label-low needs a folder")))),
            "--cwd" => o.cwd = Some(PathBuf::from(it.next().unwrap_or_else(|| fail("--cwd needs a folder")))),
            "--path-first" => o.path_first.push(it.next().unwrap_or_else(|| fail("--path-first needs a folder"))),
            "--medium" => o.medium = true,
            "--" => { o.cmd = it.collect(); break }
            other => fail(&format!("unknown option {other} (put the command after --)")),
        }
    }
    if o.cmd.is_empty() { fail("no command given after --") }
    if o.timeout == 0 || o.mem_mb < 64 || o.procs == 0 { fail("--timeout must be > 0, --mem >= 64, --procs > 0") }
    o
}

// Folders this program may relabel Low: only under the real TEMP folder or the kitchen's own state folder. Never a repo, never the
// home folder: a Low label there would let every Low process on the machine (browser sandboxes included) write Jordan's files.
fn allowed_roots() -> Vec<String> {
    let mut r = vec![];
    if let Some(t) = std::env::var_os("TEMP") { r.push(PathBuf::from(t)) }
    if let Some(l) = std::env::var_os("LOCALAPPDATA") { r.push(PathBuf::from(l).join("brain-kitchen")) }
    r.into_iter().filter_map(|p| std::fs::canonicalize(p).ok()).map(|p| p.to_string_lossy().to_lowercase().trim_start_matches(r"\\?\").to_string()).collect()
}
fn check_allowed(p: &Path, roots: &[String]) -> PathBuf {
    let c = std::fs::canonicalize(p).unwrap_or_else(|e| fail(&format!("cannot resolve {}: {e}", p.display())));
    // canonicalize returns a \\?\C:\... verbatim path; children (pwsh, git, cmd) choke on that in TEMP/HOME, so hand out the plain form
    let c = match c.to_str().and_then(|s| s.strip_prefix(r"\\?\")) { Some(s) if !s.starts_with("UNC\\") => PathBuf::from(s), _ => c };
    let s = c.to_string_lossy().to_lowercase();
    if !roots.iter().any(|r| s.len() > r.len() + 1 && s.starts_with(r.as_str()) && s.as_bytes()[r.len()] == b'\\') {
        fail(&format!("refusing to label {} Low: only folders under TEMP or %LOCALAPPDATA%\\brain-kitchen", p.display()))
    }
    c
}
fn label_low(dir: &Path, recurse: bool) {
    // icacls ships with Windows; (OI)(CI) makes new files and folders inside inherit the Low label. /T relabels what already exists.
    let mut c = Command::new("icacls.exe");
    c.arg(dir).arg("/setintegritylevel").arg("(OI)(CI)low").arg("/Q");
    if recurse { c.arg("/T").arg("/C"); }
    let out = c.output().unwrap_or_else(|e| fail(&format!("icacls did not start: {e}")));
    if !out.status.success() { fail(&format!("icacls could not label {} Low: {}", dir.display(), String::from_utf8_lossy(&out.stdout).trim())) }
}

// Windows command-line quoting (the rules CommandLineToArgvW and the MSVC runtime parse back).
fn quote(arg: &OsStr, out: &mut Vec<u16>) {
    let a: Vec<u16> = arg.encode_wide().collect();
    let needs = a.is_empty() || a.iter().any(|&c| c == b' ' as u16 || c == b'\t' as u16 || c == b'"' as u16);
    if !needs { out.extend_from_slice(&a); return }
    out.push(b'"' as u16);
    let mut bs = 0usize;
    for &c in &a {
        if c == b'\\' as u16 { bs += 1; continue }
        if c == b'"' as u16 { out.extend(std::iter::repeat(b'\\' as u16).take(bs * 2 + 1)); } else { out.extend(std::iter::repeat(b'\\' as u16).take(bs)); }
        bs = 0; out.push(c);
    }
    out.extend(std::iter::repeat(b'\\' as u16).take(bs * 2));
    out.push(b'"' as u16);
}

fn env_block(scratch: Option<&Path>, path_first: &[OsString]) -> Vec<u16> {
    let mut vars: Vec<(OsString, OsString)> = std::env::vars_os().collect();
    // --path-first: these folders go to the front of PATH. The kitchen puts the real pwsh folder ($PSHOME) there: a nested `pwsh` found
    // through the Microsoft Store alias stub (%LOCALAPPDATA%\Microsoft\WindowsApps) at Low integrity now and then started with a
    // mangled command line ("Processing -File ...pwsh.exe failed"), 2 runs in 4 of Test-KitchenFreshen; the real exe never did.
    if !path_first.is_empty() {
        let old = vars.iter().position(|(k, _)| k.to_string_lossy().eq_ignore_ascii_case("PATH")).map(|i| vars.remove(i).1).unwrap_or_default();
        let mut p = OsString::new();
        for d in path_first { p.push(d); p.push(";"); }
        p.push(old);
        vars.push(("PATH".into(), p));
    }
    if let Some(s) = scratch {
        let sub = |n: &str| { let p = s.join(n); let _ = std::fs::create_dir_all(&p); p.into_os_string() };
        let home = sub("home");
        let gitcfg = s.join("gitconfig");
        // an identity so suites that commit in their own temp repos still work; nothing else (no hooks path, no fsmonitor, no includes)
        let _ = std::fs::write(&gitcfg, "[user]\n\tname = kitchen-test\n\temail = kitchen-test@localhost\n[init]\n\tdefaultBranch = main\n");
        let tmp = sub("tmp");
        let set: Vec<(&str, OsString)> = vec![
            ("TEMP", tmp.clone()), ("TMP", tmp), ("USERPROFILE", home.clone()), ("HOME", home),
            ("APPDATA", sub("appdata")), ("LOCALAPPDATA", sub("localappdata")),
            ("GIT_CONFIG_NOSYSTEM", "1".into()), ("GIT_CONFIG_GLOBAL", gitcfg.into_os_string()), ("KITCHEN_SANDBOX", "1".into()),
        ];
        for (k, v) in set {
            vars.retain(|(n, _)| !n.to_string_lossy().eq_ignore_ascii_case(k));
            vars.push((k.into(), v));
        }
    }
    vars.sort_by_key(|(k, _)| k.to_string_lossy().to_uppercase());
    let mut b = vec![];
    for (k, v) in vars { b.extend(k.encode_wide()); b.push(b'=' as u16); b.extend(v.encode_wide()); b.push(0); }
    b.push(0);
    b
}

fn main() {
    let o = parse();
    let roots = allowed_roots();
    let scratch = o.scratch.as_ref().map(|s| {
        std::fs::create_dir_all(s).unwrap_or_else(|e| fail(&format!("cannot create scratch {}: {e}", s.display())));
        let c = check_allowed(s, &roots);
        if !o.medium { label_low(&c, true) }
        c
    });
    for d in &o.label_low { let c = check_allowed(d, &roots); if !o.medium { label_low(&c, true) } }
    let env = env_block(scratch.as_deref(), &o.path_first);
    let mut cmdline = vec![];
    for (i, a) in o.cmd.iter().enumerate() { if i > 0 { cmdline.push(b' ' as u16) } quote(a, &mut cmdline) }
    cmdline.push(0);
    let cwd = o.cwd.as_ref().map(|c| wide(c.as_os_str()));

    unsafe {
        // 1. the job: whole tree dies with this launcher, with the timeout, or past the memory cap; no more than N live processes
        let job = CreateJobObjectW(null(), null());
        if job.is_null() { fail(&format!("CreateJobObject: {}", last_err())) }
        let mut lim = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        lim.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_JOB_MEMORY | JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        lim.BasicLimitInformation.ActiveProcessLimit = o.procs;
        // the hard cap sits 50% above --mem: a commit past the HARD cap just fails inside the child (an OutOfMemory it may swallow) and
        // Windows posts no message for that, so the sandbox could not tell. The notification limit at --mem posts a message the moment
        // the tree goes past it, and this launcher then kills the tree with 125 (the same rule run-bounded used: over MaxMB = killed).
        // Why 50% and not 25% (it was 1.25x until 10-24): .NET (pwsh) sets its GC heap limit to 75% of the job's hard limit, so at 1.25x
        // one pwsh process hit OutOfMemory at 0.75 x 1.25 = 94% of --mem, never reached the notification limit, and was never killed
        // (measured: --mem 1024 refused it at 955 MB, --mem 300 at 290 MB, exit 0). At 1.5x that limit is 112% of --mem, so the tree
        // passes --mem first, the same 1.5x wall run-bounded.ps1 uses.
        lim.JobMemoryLimit = (o.mem_mb as usize) * 1024 * 1024 / 2 * 3;
        if SetInformationJobObject(job, JOB_EXTENDED_LIMIT_INFORMATION, &lim as *const _ as *const c_void, std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32) == 0 {
            fail(&format!("SetInformationJobObject(limits): {}", last_err()))
        }
        let nl = JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION { IoReadBytesLimit: 0, IoWriteBytesLimit: 0, PerJobUserTimeLimit: 0, JobMemoryLimit: o.mem_mb * 1024 * 1024,
                                                           RateControlTolerance: 1, RateControlToleranceInterval: 1, LimitFlags: JOB_OBJECT_LIMIT_JOB_MEMORY };
        if SetInformationJobObject(job, JOB_NOTIFICATION_LIMIT_INFORMATION, &nl as *const _ as *const c_void, std::mem::size_of::<JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION>() as u32) == 0 {
            fail(&format!("SetInformationJobObject(notification): {}", last_err()))
        }
        let port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null_mut(), 0, 1);
        if port.is_null() { fail(&format!("CreateIoCompletionPort: {}", last_err())) }
        let assoc = JOBOBJECT_ASSOCIATE_COMPLETION_PORT { CompletionKey: job, CompletionPort: port };
        if SetInformationJobObject(job, JOB_ASSOCIATE_COMPLETION_PORT, &assoc as *const _ as *const c_void, std::mem::size_of::<JOBOBJECT_ASSOCIATE_COMPLETION_PORT>() as u32) == 0 {
            fail(&format!("SetInformationJobObject(port): {}", last_err()))
        }

        // 2. the token: a copy of ours, lowered to Low integrity (lowering your own token needs no privilege)
        let mut tok: HANDLE = null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT | TOKEN_ASSIGN_PRIMARY, &mut tok) == 0 { fail(&format!("OpenProcessToken: {}", last_err())) }
        let mut ntok: HANDLE = null_mut();
        if DuplicateTokenEx(tok, MAXIMUM_ALLOWED, null(), SECURITY_IMPERSONATION, TOKEN_PRIMARY, &mut ntok) == 0 { fail(&format!("DuplicateTokenEx: {}", last_err())) }
        if !o.medium {
            let mut sid: *mut c_void = null_mut();
            if ConvertStringSidToSidW(wide(OsStr::new("S-1-16-4096")).as_ptr(), &mut sid) == 0 { fail(&format!("ConvertStringSidToSid: {}", last_err())) }
            let tml = TOKEN_MANDATORY_LABEL { Label: SID_AND_ATTRIBUTES { Sid: sid, Attributes: SE_GROUP_INTEGRITY } };
            let len = std::mem::size_of::<TOKEN_MANDATORY_LABEL>() as u32 + GetLengthSid(sid);
            if SetTokenInformation(ntok, TOKEN_INTEGRITY_LEVEL, &tml as *const _ as *const c_void, len) == 0 { fail(&format!("SetTokenInformation(Low): {}", last_err())) }
            LocalFree(sid);
        }

        // 3. start suspended with our stdio, join the job, then let it run
        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        si.dwFlags = STARTF_USESTDHANDLES;
        let hs: Vec<HANDLE> = STD_HANDLES.iter().map(|&w| GetStdHandle(w)).collect();
        for &h in &hs { if !h.is_null() && h != INVALID_HANDLE_VALUE { SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT); } }
        si.hStdInput = hs[0]; si.hStdOutput = hs[1]; si.hStdError = hs[2];
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        if CreateProcessAsUserW(ntok, null(), cmdline.as_mut_ptr(), null(), null(), 1, CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                                env.as_ptr() as *const c_void, cwd.as_ref().map_or(null(), |c| c.as_ptr()), &si, &mut pi) == 0 {
            fail(&format!("could not start {}: {}", o.cmd[0].to_string_lossy(), last_err()))
        }
        if AssignProcessToJobObject(job, pi.hProcess) == 0 {
            let e = last_err(); TerminateProcess(pi.hProcess, EXIT_SANDBOX as u32); fail(&format!("AssignProcessToJobObject: {e}"))
        }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread); CloseHandle(ntok); CloseHandle(tok);

        let deadline = Instant::now() + Duration::from_secs(o.timeout);
        let mut mem_hit = false;
        let mem_killed = |job: HANDLE| { TerminateJobObject(job, EXIT_MEMORY as u32); eprintln!("kitchen-sandbox: killed the tree (exit 125: memory cap {} MB)", o.mem_mb); EXIT_MEMORY };
        let code: i32 = loop {
            let (mut msg, mut key, mut ov) = (0u32, 0usize, null_mut());
            while GetQueuedCompletionStatus(port, &mut msg, &mut key, &mut ov, 0) != 0 {
                if msg == JOB_OBJECT_MSG_JOB_MEMORY_LIMIT || msg == JOB_OBJECT_MSG_NOTIFICATION_LIMIT { mem_hit = true }
                if msg == JOB_OBJECT_MSG_ACTIVE_PROCESS_LIMIT { eprintln!("kitchen-sandbox: process limit ({}) reached; a child process was refused", o.procs) }
            }
            if mem_hit { break mem_killed(job) }
            if WaitForSingleObject(pi.hProcess, 200) == 0 {
                let mut c = 0u32; GetExitCodeProcess(pi.hProcess, &mut c);
                // the notification arrives a little after the fact, so the job's own peak decides: a tree that went past --mem and then
                // exited still reports 125, never a pass
                let mut q = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
                let peak_over = QueryInformationJobObject(job, JOB_EXTENDED_LIMIT_INFORMATION, &mut q as *mut _ as *mut c_void, std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32, null_mut()) != 0
                    && q.PeakJobMemoryUsed as u64 > o.mem_mb * 1024 * 1024;
                if peak_over { break mem_killed(job) }
                // leftovers (background children) die with the job: nothing the suite started keeps running after it
                TerminateJobObject(job, c);
                break c as i32;
            }
            if Instant::now() >= deadline {
                TerminateJobObject(job, EXIT_TIMEOUT as u32);
                eprintln!("kitchen-sandbox: killed the tree (exit 124: timeout {}s)", o.timeout);
                break EXIT_TIMEOUT;
            }
        };
        CloseHandle(pi.hProcess); CloseHandle(port); CloseHandle(job);
        std::process::exit(code);
    }
}