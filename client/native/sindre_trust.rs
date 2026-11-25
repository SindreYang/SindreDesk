//! Local LAN trust-on-first-successful-login. Discovery is not a trust source.
use hbb_common::{anyhow::anyhow, bail, config::Config, ResultType};
use std::{fs, io::Write, net::{Ipv4Addr, SocketAddrV4}, path::PathBuf};

fn path(peer: &str) -> ResultType<PathBuf> {
    let ip = if let Ok(ip) = peer.parse::<Ipv4Addr>() {
        ip
    } else {
        let addr = peer.parse::<SocketAddrV4>()?;
        if addr.port() != hbb_common::config::SINDRE_LAN_DIRECT_PORT {
            bail!("Invalid LAN port");
        }
        *addr.ip()
    };
    if !ip.is_private() { bail!("Private IPv4 required"); }
    let root = Config::path("sindre-lan-trust-v1");
    if !root.is_absolute() { bail!("LAN trust directory unavailable"); }
    Ok(root.join(format!("{ip}.key")))
}

fn check_path(path: &std::path::Path, key: &[u8]) -> ResultType<bool> {
    if key.len() != hbb_common::sodiumoxide::crypto::sign::PUBLICKEYBYTES {
        bail!("Invalid LAN identity");
    }
    match fs::read(path) {
        Ok(saved) if saved == key => Ok(true),
        Ok(_) => bail!("被控设备已变化，请确认连接地址；如确需更换设备，可在设置中清除本机局域网信任记录"),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.into()),
    }
}

pub(crate) fn check(peer: &str, key: &[u8]) -> ResultType<()> {
    let result = check_path(&path(peer)?, key);
    if result.is_err() {
        crate::sindre_diag::record("lan-identity-rejected", None, None);
    }
    result.map(|_| ())
}

pub(crate) fn remember(peer: &str, key: &[u8]) -> ResultType<()> {
    let target = path(peer)?;
    if check_path(&target, key)? { return Ok(()); }
    let parent = target.parent().ok_or_else(|| anyhow!("LAN trust path unavailable"))?;
    fs::create_dir_all(parent)?;
    // Publish only a complete record, never overwrite a concurrently trusted key.
    let tmp = parent.join(format!(".{}.{}.tmp", std::process::id(), uuid::Uuid::new_v4()));
    let result = (|| -> ResultType<()> {
        let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        file.write_all(key)?;
        file.sync_all()?;
        drop(file);
        match fs::hard_link(&tmp, &target) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                if check_path(&target, key)? { Ok(()) } else { Err(e.into()) }
            }
            Err(e) => Err(e.into()),
        }
    })();
    let _ = fs::remove_file(tmp);
    if result.is_ok() { crate::sindre_diag::record("lan-trust-saved", None, None); }
    result
}

pub(crate) fn clear() -> ResultType<()> {
    let root = Config::path("sindre-lan-trust-v1");
    if !root.is_absolute() { bail!("LAN trust directory unavailable"); }
    match fs::remove_dir_all(root) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}
