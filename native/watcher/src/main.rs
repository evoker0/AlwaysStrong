// AlwaysStrong package watcher.
//
// Three jobs, all event-driven:
//   1. inotify on /data/system (MOVED_TO|CREATE) — re-runs build_target_txt.sh
//      when packages.list is replaced (PackageManager writes a temp file then
//      renames, so the inode-stable watch is on the parent dir).
//   2. Xposed exclusion — pm-checks known Xposed managers and strips them from
//      target.txt; attesting through a hooked process defeats STRONG.
//   3. Conflict scan — lists active sibling modules from a known clone list.
//
// Subcommands:
//   aswatcher              -> daemon (default, called from service.sh)
//   aswatcher rescan       -> rebuild target.txt once
//   aswatcher xposed       -> Xposed exclusion once
//   aswatcher conflict     -> conflict check; exit code = active conflict count

use std::env;
use std::fs;
use std::path::Path;
use std::process::{Command, exit};
use std::thread;
use std::time::Duration;

use inotify::{Inotify, WatchMask};

const BUILDER:     &str = "build_target_txt.sh";
const TARGET_TXT:  &str = "/data/adb/tricky_store/target.txt";
const PKG_DIR:     &str = "/data/system";
const PKG_FILE:    &str = "packages.list";
const LOG_TAG:     &str = "AlwaysStrong";

const XPOSED_PKGS: &[&str] = &[
    "de.robv.android.xposed.installer",
    "org.lsposed.manager",
    "io.github.lsposed.manager",
    "org.meowcat.edxposed.manager",
    "com.solohsu.android.edxp.manager",
    "io.va.exposed",
    "com.topjohnwu.lsplant.manager",
];

const CONFLICT_MODS: &[&str] = &[
    "playintegrityfix", "playintegrityfork", "play_integrity_fix",
    "playcurl", "playcurlNEXT", "tricky_store_v2", "TrickyStore",
    "tee_simulator", "TEESimulator", "TEESimulator-RS",
    "safetynet-fix", "Universal_SafetyNet_Fix", "MagiskHidePropsConf",
    "pif_strong", "pif_force",
];

fn log_msg(msg: &str) {
    let _ = Command::new("log").args(["-t", LOG_TAG, msg]).status();
}

// /data/adb/modules/<id>/bin/<abi>/aswatcher  ->  /data/adb/modules/<id>
fn module_dir() -> String {
    env::current_exe()
        .ok()
        .and_then(|p| p.parent().and_then(|p| p.parent()).and_then(|p| p.parent()).map(|p| p.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "/data/adb/modules/tricky_store".to_string())
}

fn rebuild() -> i32 {
    let builder = format!("{}/{}", module_dir(), BUILDER);
    if !Path::new(&builder).exists() {
        log_msg(&format!("builder missing: {}", builder));
        return 1;
    }
    match Command::new("sh").arg(&builder).arg(TARGET_TXT).output() {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let s = stdout.trim();
            if !s.is_empty() { log_msg(s); }
            out.status.code().unwrap_or(if out.status.success() { 0 } else { 1 })
        }
        Err(e) => { log_msg(&format!("builder spawn failed: {}", e)); 1 }
    }
}

fn pm_installed(pkg: &str) -> bool {
    Command::new("pm").args(["path", pkg]).output()
        .map(|o| o.status.success() && !o.stdout.is_empty())
        .unwrap_or(false)
}

fn strip_suffix(s: &str) -> &str {
    s.strip_suffix('!').or_else(|| s.strip_suffix('?')).unwrap_or(s)
}

fn xposed_scan() -> i32 {
    let Ok(content) = fs::read_to_string(TARGET_TXT) else { return 0; };
    let before = content.lines().count();
    let mut kept: Vec<&str> = content.lines().collect();
    for pkg in XPOSED_PKGS {
        if !pm_installed(pkg) { continue; }
        let len_before = kept.len();
        kept.retain(|l| strip_suffix(l.trim()) != *pkg);
        if kept.len() != len_before {
            log_msg(&format!("excluded xposed pkg {}", pkg));
        }
    }
    if kept.len() != before {
        let mut new = kept.join("\n");
        new.push('\n');
        let _ = fs::write(TARGET_TXT, new);
    }
    0
}

fn conflict_check() -> i32 {
    let moddir = module_dir();
    let self_id = Path::new(&moddir).file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut n: i32 = 0;
    for c in CONFLICT_MODS {
        if *c == self_id.as_str() { continue; }
        let d = format!("/data/adb/modules/{}", c);
        let p = Path::new(&d);
        if p.exists() && !p.join("disable").exists() && !p.join("remove").exists() {
            log_msg(&format!("conflict still active: {}", c));
            n += 1;
        }
    }
    n
}

fn wait_for_pm() {
    for _ in 0..30 {
        if Command::new("pm").args(["list", "packages"]).output()
            .map(|o| o.status.success()).unwrap_or(false) { return; }
        thread::sleep(Duration::from_secs(2));
    }
}

fn run_inotify() -> std::io::Result<()> {
    let mut inotify = Inotify::init()?;
    inotify.watches().add(PKG_DIR, WatchMask::MOVED_TO | WatchMask::CREATE)?;
    let mut buf = [0u8; 4096];
    loop {
        let events = inotify.read_events_blocking(&mut buf)?;
        let mut fire = false;
        for ev in events {
            if let Some(name) = ev.name {
                if name == PKG_FILE { fire = true; }
            }
        }
        if fire {
            rebuild();
            xposed_scan();
        }
    }
}

fn daemon_loop() -> ! {
    wait_for_pm();
    rebuild();
    xposed_scan();
    conflict_check();
    loop {
        if let Err(e) = run_inotify() {
            log_msg(&format!("inotify error: {}; reopening in 30s", e));
            thread::sleep(Duration::from_secs(30));
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("daemon");
    let code: i32 = match cmd {
        "rescan"   => rebuild(),
        "xposed"   => xposed_scan(),
        "conflict" => conflict_check(),
        "daemon" | "" => daemon_loop(),
        _ => { eprintln!("usage: aswatcher [rescan|xposed|conflict|daemon]"); 1 }
    };
    exit(code);
}
