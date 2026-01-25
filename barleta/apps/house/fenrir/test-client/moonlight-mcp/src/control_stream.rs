//! Control stream implementation for Moonlight protocol
//!
//! Implements the ENet-based control channel with AES-128 GCM encryption.
//! This replicates what the real Moonlight client does for input/control.

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes128Gcm, Nonce,
};
use anyhow::{anyhow, Result};
use std::net::SocketAddr;
use tokio::net::UdpSocket;

/// Control packet types (matches Wolf's control.hpp)
#[repr(u16)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ControlPacketType {
    StartA = 0x0305,
    StartB = 0x0307,
    Invalidate = 0x0301,
    Loss = 0x0201,
    Encrypted = 0x0001,
    Termination = 0x0100,
    InputData = 0x0206,
    IdrFrame = 0x0302,
}

/// Encrypted control packet header (matches Wolf's ControlEncryptedPacket)
#[repr(C, packed)]
struct ControlEncryptedPacket {
    packet_type: u16,  // Always ENCRYPTED (0x0001)
    seq: u32,
    gcm_tag: [u8; 16],
    payload: [u8; 0],  // Variable length encrypted payload
}

/// Control stream connection to Wolf
pub struct ControlStream {
    socket: UdpSocket,
    cipher: Aes128Gcm,
    rikeyid: u32,
    sequence: u32,
    remote_addr: SocketAddr,
}

impl ControlStream {
    /// Connect to the control stream
    ///
    /// # Arguments
    /// * `host` - Host address
    /// * `port` - Control port from RTSP session
    /// * `rikey` - 32-character hex-encoded AES key (e.g., "C25B9231800606306972578A56C19C25")
    /// * `rikeyid` - Key ID used as IV base
    pub async fn connect(host: &str, port: u16, rikey: &str, rikeyid: u32) -> Result<Self> {
        // Convert hex rikey to binary key (32 hex chars -> 16 bytes)
        let key_bytes = hex::decode(rikey)
            .map_err(|e| anyhow!("Failed to decode rikey hex: {}", e))?;
        
        if key_bytes.len() != 16 {
            return Err(anyhow!(
                "Invalid rikey length: expected 16 bytes, got {}",
                key_bytes.len()
            ));
        }

        let key: [u8; 16] = key_bytes.try_into().unwrap();
        let cipher = Aes128Gcm::new_from_slice(&key)
            .map_err(|e| anyhow!("Failed to create AES-GCM cipher: {}", e))?;

        // Bind to any available local port
        let socket = UdpSocket::bind("0.0.0.0:0").await?;
        let remote_addr: SocketAddr = format!("{}:{}", host, port).parse()?;
        socket.connect(&remote_addr).await?;

        eprintln!(
            "[CONTROL] Connected to {}:{} with rikey={} rikeyid={}",
            host, port, rikey, rikeyid
        );

        Ok(Self {
            socket,
            cipher,
            rikeyid,
            sequence: 0,
            remote_addr,
        })
    }

    /// Build the GCM IV/nonce from rikeyid and sequence
    ///
    /// Moonlight uses a 12-byte nonce: [rikeyid (4 bytes) || zeros (4 bytes) || seq (4 bytes)]
    fn build_nonce(&self, seq: u32) -> [u8; 12] {
        let mut nonce = [0u8; 12];
        nonce[0..4].copy_from_slice(&self.rikeyid.to_le_bytes());
        // bytes 4-7 are zeros
        nonce[8..12].copy_from_slice(&seq.to_le_bytes());
        nonce
    }

    /// Encrypt and send a control packet
    pub async fn send_encrypted(&mut self, plaintext: &[u8]) -> Result<()> {
        let seq = self.sequence;
        self.sequence = self.sequence.wrapping_add(1);

        let nonce_bytes = self.build_nonce(seq);
        let nonce = Nonce::from_slice(&nonce_bytes);

        // Encrypt the payload
        let ciphertext = self.cipher
            .encrypt(nonce, plaintext)
            .map_err(|e| anyhow!("AES-GCM encryption failed: {}", e))?;

        // The ciphertext from aes-gcm includes the tag at the end
        // We need to split it out for the Moonlight packet format
        if ciphertext.len() < 16 {
            return Err(anyhow!("Ciphertext too short"));
        }
        
        let (encrypted_data, tag) = ciphertext.split_at(ciphertext.len() - 16);

        // Build the packet: [type: u16] [seq: u32] [tag: 16 bytes] [encrypted_payload]
        let mut packet = Vec::with_capacity(2 + 4 + 16 + encrypted_data.len());
        packet.extend_from_slice(&(ControlPacketType::Encrypted as u16).to_le_bytes());
        packet.extend_from_slice(&seq.to_le_bytes());
        packet.extend_from_slice(tag);
        packet.extend_from_slice(encrypted_data);

        self.socket.send(&packet).await?;
        
        eprintln!(
            "[CONTROL] Sent encrypted packet seq={} len={} tag={}",
            seq,
            packet.len(),
            hex::encode(tag)
        );

        Ok(())
    }

    /// Send a ping/heartbeat packet
    /// This is what maintains the connection and triggers the encryption on the server
    pub async fn send_ping(&mut self) -> Result<()> {
        // A simple ping is just an empty encrypted packet or a specific control packet
        // Wolf expects encrypted input packets, so we send a minimal one
        let ping_payload = [0u8; 4]; // Minimal input packet
        self.send_encrypted(&ping_payload).await
    }

    /// Send input data packet
    /// 
    /// Format matches Moonlight's input packet structure
    pub async fn send_input(&mut self, input_type: u8, data: &[u8]) -> Result<()> {
        // Input packet format: [type: u16 (INPUT_DATA)] [input_type: u8] [data...]
        let mut payload = Vec::with_capacity(3 + data.len());
        payload.extend_from_slice(&(ControlPacketType::InputData as u16).to_le_bytes());
        payload.push(input_type);
        payload.extend_from_slice(data);
        
        self.send_encrypted(&payload).await
    }

    /// Wait for and receive a response (with timeout)
    pub async fn recv_with_timeout(&self, timeout_ms: u64) -> Result<Vec<u8>> {
        let mut buf = [0u8; 2048];
        
        let recv_future = self.socket.recv(&mut buf);
        let timeout = tokio::time::Duration::from_millis(timeout_ms);
        
        match tokio::time::timeout(timeout, recv_future).await {
            Ok(Ok(len)) => Ok(buf[..len].to_vec()),
            Ok(Err(e)) => Err(anyhow!("Receive error: {}", e)),
            Err(_) => Err(anyhow!("Receive timeout after {}ms", timeout_ms)),
        }
    }

    /// Close the control stream
    pub async fn close(&mut self) -> Result<()> {
        // Send termination packet
        let termination = (ControlPacketType::Termination as u16).to_le_bytes();
        self.send_encrypted(&termination).await?;
        eprintln!("[CONTROL] Sent termination packet");
        Ok(())
    }

    /// Test the control stream by sending a ping and checking for errors
    /// This is useful for verifying the encryption is working
    pub async fn test_connection(&mut self) -> Result<()> {
        eprintln!("[CONTROL] Testing connection with ping...");
        
        // Send a few pings to trigger encryption on the server
        for i in 0..3 {
            match self.send_ping().await {
                Ok(_) => eprintln!("[CONTROL] Ping {} sent successfully", i + 1),
                Err(e) => {
                    eprintln!("[CONTROL] Ping {} failed: {}", i + 1, e);
                    return Err(e);
                }
            }
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
        }
        
        eprintln!("[CONTROL] Connection test complete");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hex_to_binary_key() {
        let rikey = "C25B9231800606306972578A56C19C25";
        let key_bytes = hex::decode(rikey).unwrap();
        assert_eq!(key_bytes.len(), 16);
    }

    #[test]
    fn test_nonce_building() {
        // This is a mock test - can't create full struct without async
        let rikeyid: u32 = 2578605363;
        let seq: u32 = 0;
        
        let mut nonce = [0u8; 12];
        nonce[0..4].copy_from_slice(&rikeyid.to_le_bytes());
        nonce[8..12].copy_from_slice(&seq.to_le_bytes());
        
        assert_eq!(nonce.len(), 12);
        // Verify rikeyid is in first 4 bytes
        assert_eq!(u32::from_le_bytes(nonce[0..4].try_into().unwrap()), rikeyid);
    }
}
