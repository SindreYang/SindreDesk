//! Local diagnostic events only: never write raw protocol messages or authentication secrets.
use std::{fs::{self, OpenOptions}, io::Write, net::SocketAddr, path::PathBuf};

pub(crate) fn record(event: &'static str, address: Option<SocketAddr>, port: Option<i32>) {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let Ok(_guard) = LOCK.lock() else { return; };
    let role = if hbb_common::config::is_incoming_only() { "Host" } else { "Client" };
    let file_name = format!("SindreDesk{role}.log");
    let mut paths: Vec<PathBuf> = Vec::new();
    // Write beside the actual executable; fall back to the application log directory.
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        if let Ok(exe) = std::env::current_exe() {
            if let Some(dir) = exe.parent() { paths.push(dir.to_path_buf()); }
        }
    }
    paths.push(hbb_common::config::Config::log_path());
    let line = format!("{} pid={} role={} event={} peer={:?} port={:?}\n",
        hbb_common::chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f"),
        std::process::id(), role, event, address, port);
    for dir in paths {
        if fs::create_dir_all(&dir).is_err() { continue; }
        let path = dir.join(&file_name);
        if fs::metadata(&path).map(|m| m.len() >= 5 * 1024 * 1024).unwrap_or(false) {
            // Preserve a bounded previous log; if rotation fails, use the fallback directory.
            let old = dir.join(format!("{file_name}.old"));
            let _ = fs::remove_file(&old);
            if fs::rename(&path, &old).is_err() { continue; }
        }
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            if file.write_all(line.as_bytes()).is_ok() { return; }
        }
    }
}
