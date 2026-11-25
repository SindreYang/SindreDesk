//! Explicit, opt-in LAN-only compatibility negotiation. Never used by relay connections.
use hbb_common::{
    anyhow::anyhow, bail, config::{Config, CONNECT_TIMEOUT},
    message_proto::{Message, PublicKey, message}, protobuf::Message as _,
    timeout, ResultType, Stream,
};
use std::net::{SocketAddr, IpAddr};

const REQUEST: &[u8] = b"SINDREDESK-LAN-PLAIN-REQUEST-v1";
const ACK: &[u8] = b"SINDREDESK-LAN-PLAIN-ACK-v1";

pub(crate) fn enabled() -> bool {
    Config::get_option("sindre-lan-compat") == "Y"
}

pub(crate) fn private_address(addr: SocketAddr) -> bool {
    match addr.ip() {
        IpAddr::V4(ip) => ip.is_private(),
        IpAddr::V6(ip) => ip.to_ipv4_mapped().map_or(false, |v4| v4.is_private()),
    }
}

fn marker(value: &[u8]) -> Message {
    let mut msg = Message::new();
    msg.set_public_key(PublicKey {
        symmetric_value: value.to_vec().into(),
        ..Default::default()
    });
    msg
}

fn matches_marker(bytes: &[u8], expected: &[u8]) -> bool {
    match Message::parse_from_bytes(bytes).ok().and_then(|m| m.union) {
        Some(message::Union::PublicKey(pk)) => {
            pk.asymmetric_value.is_empty() && pk.symmetric_value.as_ref() == expected
        }
        _ => false,
    }
}

pub(crate) fn is_request(bytes: &[u8]) -> bool {
    matches_marker(bytes, REQUEST)
}

pub(crate) async fn send_request(stream: &mut Stream) -> ResultType<()> {
    timeout(CONNECT_TIMEOUT, stream.send(&marker(REQUEST))).await??;
    Ok(())
}

pub(crate) async fn send_ack(stream: &mut Stream) -> ResultType<()> {
    timeout(CONNECT_TIMEOUT, stream.send(&marker(ACK))).await??;
    Ok(())
}

pub(crate) async fn receive_ack(stream: &mut Stream) -> ResultType<()> {
    let bytes = timeout(CONNECT_TIMEOUT, stream.next()).await?
        .ok_or_else(|| anyhow!("LAN compatibility peer closed"))??;
    if !matches_marker(&bytes, ACK) {
        bail!("被控端未开启局域网兼容模式或版本不一致");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_markers_are_distinct() {
        let request = marker(REQUEST).write_to_bytes().unwrap();
        let ack = marker(ACK).write_to_bytes().unwrap();
        assert!(is_request(&request));
        assert!(!is_request(&ack));
        assert!(matches_marker(&ack, ACK));
        assert!(!matches_marker(&request, ACK));
        assert!(!is_request(&[]));
    }

    #[test]
    fn only_private_ipv4() {
        assert!(private_address("192.168.5.10:32118".parse().unwrap()));
        assert!(private_address("[::ffff:192.168.5.10]:32118".parse().unwrap()));
        assert!(!private_address("8.8.8.8:32118".parse().unwrap()));
        assert!(!private_address("[2001:db8::1]:32118".parse().unwrap()));
    }
}
