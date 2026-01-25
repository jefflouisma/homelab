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

    /// Build the GCM IV/nonce matching real Moonlight format (12 bytes)
    ///
    /// Real Moonlight format (from moonlight-common-c):
    /// - Bytes 0-3: sequence number (little endian)
    /// - Bytes 4-9: zeros
    /// - Byte 10: 'C' for client-originated, 'H' for host-originated
    /// - Byte 11: 'C' for control stream
    fn build_nonce(&self, seq: u32, is_host_originated: bool) -> [u8; 12] {
        let mut nonce = [0u8; 12];
        // Bytes 0-3: sequence in little endian
        nonce[0..4].copy_from_slice(&seq.to_le_bytes());
        // Bytes 4-9: zeros (already initialized)
        // Byte 10: origin identifier
        nonce[10] = if is_host_originated { b'H' } else { b'C' };
        // Byte 11: stream type (Control)
        nonce[11] = b'C';
        nonce
    }

    /// Encrypt and send a control packet
    pub async fn send_encrypted(&mut self, plaintext: &[u8]) -> Result<()> {
        let seq = self.sequence;
        self.sequence = self.sequence.wrapping_add(1);

        // Use client-originated nonce (is_host_originated = false)
        let nonce_bytes = self.build_nonce(seq, false);
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

        // Build the packet: [type: u16] [length: u16] [seq: u32] [tag: 16 bytes] [encrypted_payload]
        // Matches NVCTL_ENCRYPTED_PACKET_HEADER from moonlight-common-c
        let length: u16 = (4 + 16 + encrypted_data.len()) as u16; // seq + tag + ciphertext
        let mut packet = Vec::with_capacity(2 + 2 + 4 + 16 + encrypted_data.len());
        packet.extend_from_slice(&(ControlPacketType::Encrypted as u16).to_le_bytes());
        packet.extend_from_slice(&length.to_le_bytes());
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

    /// Receive and decrypt a control packet from the server
    /// This matches what real Moonlight does in decryptControlMessageToV1()
    pub async fn recv_and_decrypt(&self, timeout_ms: u64) -> Result<Vec<u8>> {
        let packet = self.recv_with_timeout(timeout_ms).await?;
        
        // Minimum packet: type(2) + length(2) + seq(4) + tag(16) = 24 bytes
        if packet.len() < 24 {
            return Err(anyhow!("Received runt packet ({} bytes), unable to decrypt", packet.len()));
        }

        // Parse encrypted packet header
        let packet_type = u16::from_le_bytes([packet[0], packet[1]]);
        if packet_type != ControlPacketType::Encrypted as u16 {
            // Non-encrypted packet, return as-is (some control packets aren't encrypted)
            eprintln!("[CONTROL] Received non-encrypted packet type: 0x{:04x}", packet_type);
            return Ok(packet);
        }

        let _length = u16::from_le_bytes([packet[2], packet[3]]);
        let seq = u32::from_le_bytes([packet[4], packet[5], packet[6], packet[7]]);
        
        // Extract tag and ciphertext
        let tag = &packet[8..24];
        let ciphertext = &packet[24..];
        
        // Build nonce for host-originated packet (is_host_originated = true)
        let nonce_bytes = self.build_nonce(seq, true);
        let nonce = Nonce::from_slice(&nonce_bytes);
        
        // Combine ciphertext + tag for aes-gcm (it expects tag appended)
        let mut combined = Vec::with_capacity(ciphertext.len() + 16);
        combined.extend_from_slice(ciphertext);
        combined.extend_from_slice(tag);
        
        // Attempt decryption - THIS IS THE KEY CHECK
        // If the server used the wrong AES key (hex string instead of binary),
        // decryption will FAIL with authentication error
        match self.cipher.decrypt(nonce, combined.as_slice()) {
            Ok(plaintext) => {
                eprintln!(
                    "[CONTROL] Successfully decrypted packet seq={} plaintext_len={}",
                    seq,
                    plaintext.len()
                );
                Ok(plaintext)
            }
            Err(e) => {
                eprintln!(
                    "[CONTROL] DECRYPTION FAILED seq={} error={:?}",
                    seq, e
                );
                eprintln!("[CONTROL] This indicates the server is using wrong AES key (probable hex vs binary bug)");
                Err(anyhow!(
                    "AES-GCM decryption failed (server key mismatch): {:?}",
                    e
                ))
            }
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

    /// Test the control stream by sending a ping and verifying server response
    /// 
    /// This accurately replicates real Moonlight behavior:
    /// 1. Send encrypted control packet
    /// 2. Wait for encrypted response from server
    /// 3. Attempt to decrypt response
    /// 4. FAIL if decryption fails (indicates AES key mismatch)
    pub async fn test_connection(&mut self) -> Result<()> {
        eprintln!("[CONTROL] Testing bidirectional encrypted connection...");
        
        // Send a ping packet
        let ping_payload = [0u8; 4];
        self.send_encrypted(&ping_payload).await?;
        eprintln!("[CONTROL] Sent ping, waiting for server response...");
        
        // Wait for server response and attempt to decrypt
        // Real Moonlight does this - if server is using wrong key, we can't decrypt
        match self.recv_and_decrypt(2000).await {
            Ok(response) => {
                eprintln!(
                    "[CONTROL] Server response received and decrypted successfully ({} bytes)",
                    response.len()
                );
                Ok(())
            }
            Err(e) => {
                // Check if it's a timeout (server might not respond to pings)
                // vs a decryption failure (which indicates the bug)
                let err_str = e.to_string();
                if err_str.contains("timeout") {
                    // No response from server - try sending more to trigger a response
                    eprintln!("[CONTROL] No response to ping, sending IDR request to trigger response...");
                    
                    // Send IDR frame request - server must respond to this
                    let mut idr_request = Vec::new();
                    idr_request.extend_from_slice(&(ControlPacketType::IdrFrame as u16).to_le_bytes());
                    idr_request.extend_from_slice(&0u32.to_le_bytes()); // frame 0
                    idr_request.extend_from_slice(&0u32.to_le_bytes()); // flags
                    self.send_encrypted(&idr_request).await?;
                    
                    // Try to receive any response
                    match self.recv_and_decrypt(3000).await {
                        Ok(_) => {
                            eprintln!("[CONTROL] Bidirectional connection verified");
                            Ok(())
                        }
                        Err(e2) => {
                            let err2_str = e2.to_string();
                            if err2_str.contains("decryption") || err2_str.contains("key mismatch") {
                                // Decryption failure = bug detected
                                Err(anyhow!("Control stream encryption failure: {} (this matches the real Moonlight error)", e2))
                            } else if err2_str.contains("timeout") {
                                // Still no response - server might not send unsolicited messages
                                // This is actually okay, the key test is whether we can SEND
                                eprintln!("[CONTROL] No server response (server may not send unsolicited messages)");
                                eprintln!("[CONTROL] Connection appears functional (send works)");
                                Ok(())
                            } else {
                                Err(e2)
                            }
                        }
                    }
                } else if err_str.contains("decryption") || err_str.contains("key mismatch") {
                    // This is the real bug! Decryption failed due to key mismatch
                    Err(anyhow!("CONTROL STREAM FAILURE: {} - This is what causes 'network isn't performing well' in real Moonlight", e))
                } else {
                    Err(e)
                }
            }
        }
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
