use anyhow::{anyhow, Result};

pub fn verify_connection(_host: &str, _port: u16) -> Result<()> {
    Err(anyhow!("Native control-stream verification is unsupported: this tool has no ENet transport. Use a native Moonlight client to establish and verify the streaming session; MOONLIGHT_INPUT_COMMAND only acknowledges input delivery."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn silent_udp_peer_must_not_pass_connection_verification() {
        let peer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let result = verify_connection("127.0.0.1", peer.local_addr().unwrap().port());
        assert!(result.is_err());
        let mut packet = [0; 1];
        assert_eq!(
            peer.try_recv(&mut packet).unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
    }
}
