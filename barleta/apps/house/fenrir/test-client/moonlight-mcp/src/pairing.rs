//! Native GameStream pairing protocol implementation
//!
//! Implements the 4-phase pairing protocol without depending on moonlight-qt:
//! - Phase 1: Send salt + client cert, receive server cert
//! - Phase 2: Send client challenge, receive challenge response  
//! - Phase 3: Send server challenge response, receive pairing secret
//! - Phase 4: Send client pairing secret, receive paired confirmation

use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use aes::Aes128;
use anyhow::{anyhow, Result};
use rand::RngCore;
use rcgen::{CertificateParams, KeyPair};
use rsa::pkcs1v15::SigningKey;
use rsa::pkcs8::DecodePrivateKey;
use rsa::signature::{SignatureEncoding, Signer};
use rsa::RsaPrivateKey;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;

/// Client identity for pairing - generated once and persisted
pub struct ClientIdentity {
    pub cert_pem: String,
    pub key_pem: String,
    pub fingerprint: String,
    key_pair: KeyPair,
}

impl ClientIdentity {
    /// Load existing identity or create new one
    pub fn load_or_create() -> Result<Self> {
        let config_dir = Self::config_dir()?;
        fs::create_dir_all(&config_dir)?;

        let cert_path = config_dir.join("client.crt");
        let key_path = config_dir.join("client.key");

        if cert_path.exists() && key_path.exists() {
            Self::load(&cert_path, &key_path)
        } else {
            let identity = Self::generate()?;
            identity.save(&cert_path, &key_path)?;
            Ok(identity)
        }
    }

    fn config_dir() -> Result<PathBuf> {
        let base = dirs::config_dir().ok_or_else(|| anyhow!("No config directory"))?;
        Ok(base.join("moonlight-mcp"))
    }

    fn generate() -> Result<Self> {
        use rsa::pkcs8::EncodePrivateKey;
        
        // Generate RSA-2048 key pair using rsa crate
        let mut rng = rand::thread_rng();
        let bits = 2048;
        let private_key = RsaPrivateKey::new(&mut rng, bits)?;
        
        // Export private key to PKCS8 PEM format
        let key_pem = private_key.to_pkcs8_pem(rsa::pkcs8::LineEnding::LF)?;
        
        // Load the key into rcgen's KeyPair
        let key_pair = KeyPair::from_pem(&key_pem)?;
        
        // Create certificate params
        let mut params = CertificateParams::new(vec!["NVIDIA GameStream Client".to_string()])?;
        params.distinguished_name.push(
            rcgen::DnType::CommonName,
            "NVIDIA GameStream Client",
        );

        // Generate self-signed cert using the RSA key
        let cert = params.self_signed(&key_pair)?;

        let cert_pem = cert.pem();

        // Calculate fingerprint (SHA256 of DER cert)
        let cert_der = cert.der();
        let fingerprint = hex::encode(Sha256::digest(cert_der.as_ref()));

        Ok(Self {
            cert_pem,
            key_pem: key_pem.to_string(),
            fingerprint,
            key_pair,
        })
    }

    fn load(cert_path: &PathBuf, key_path: &PathBuf) -> Result<Self> {
        let cert_pem = fs::read_to_string(cert_path)?;
        let key_pem = fs::read_to_string(key_path)?;

        // Parse the key pair
        let key_pair = KeyPair::from_pem(&key_pem)?;

        // Calculate fingerprint from cert
        let cert_der = pem::parse(&cert_pem)?.into_contents();
        let fingerprint = hex::encode(Sha256::digest(&cert_der));

        Ok(Self {
            cert_pem,
            key_pem,
            fingerprint,
            key_pair,
        })
    }

    fn save(&self, cert_path: &PathBuf, key_path: &PathBuf) -> Result<()> {
        fs::write(cert_path, &self.cert_pem)?;
        fs::write(key_path, &self.key_pem)?;
        Ok(())
    }

    /// Get the hex-encoded certificate for pairing requests
    pub fn cert_hex(&self) -> String {
        hex::encode(self.cert_pem.as_bytes())
    }
}

/// Pairing session state
pub struct PairingSession {
    host: String,
    unique_id: String,
    identity: ClientIdentity,
    salt: Vec<u8>,
    aes_key: Vec<u8>,
    server_cert_pem: Option<String>,
    client_challenge: Vec<u8>,
    server_challenge: Vec<u8>,
    client_secret: Vec<u8>,
}

impl PairingSession {
    pub fn new(host: &str) -> Result<Self> {
        let identity = ClientIdentity::load_or_create()?;
        let mut salt = vec![0u8; 16];
        rand::thread_rng().fill_bytes(&mut salt);

        Ok(Self {
            host: host.to_string(),
            unique_id: "moonlight-mcp-e2e".to_string(),
            identity,
            salt,
            aes_key: Vec::new(),
            server_cert_pem: None,
            client_challenge: Vec::new(),
            server_challenge: Vec::new(),
            client_secret: Vec::new(),
        })
    }

    /// Execute the full 4-phase pairing protocol
    pub async fn pair(&mut self, pin: &str) -> Result<()> {
        // Derive AES key from salt + PIN
        self.aes_key = Self::derive_aes_key(&self.salt, pin);

        // Phase 1: Get server certificate (handles async PIN submission via API)
        let server_cert = self.phase1(pin).await?;
        self.server_cert_pem = Some(server_cert);

        // Phase 2: Client challenge
        self.phase2().await?;

        // Phase 3: Server challenge response
        self.phase3().await?;

        // Phase 4: Complete pairing
        self.phase4().await?;

        Ok(())
    }

    fn derive_aes_key(salt: &[u8], pin: &str) -> Vec<u8> {
        let mut hasher = Sha256::new();
        hasher.update(&salt[..16.min(salt.len())]);
        hasher.update(pin.as_bytes());
        hasher.finalize()[..16].to_vec()
    }

    async fn phase1(&self, pin: &str) -> Result<String> {
        let host = self.host.clone();
        let unique_id = self.unique_id.clone();
        let salt = self.salt.clone();
        let cert_hex = self.identity.cert_hex();

        // Spawn phase1 request in background (will block until PIN is submitted)
        let phase1_handle = tokio::spawn(async move {
            let url = format!(
                "http://{}:47989/pair?uniqueid={}&uuid={}&devicename=moonlight-mcp&updateState=1&phrase=getservercert&salt={}&clientcert={}",
                host,
                unique_id,
                uuid::Uuid::new_v4(),
                hex::encode(&salt),
                cert_hex
            );

            let client = reqwest::Client::builder()
                .danger_accept_invalid_certs(true)
                .timeout(std::time::Duration::from_secs(60))
                .build()?;

            let response = client.get(&url).send().await?;
            let body = response.text().await?;

            // Parse XML response for plaincert
            if let Some(start) = body.find("<plaincert>") {
                if let Some(end) = body.find("</plaincert>") {
                    let cert_hex = &body[start + 11..end];
                    let cert_pem = String::from_utf8(hex::decode(cert_hex)?)?;
                    return Ok(cert_pem);
                }
            }

            // Check for paired=0 (error)
            if body.contains("<paired>0</paired>") {
                return Err(anyhow!("Pairing failed in phase 1: {}", body));
            }

            Err(anyhow!("Invalid phase 1 response: {}", body))
        });

        // Give server time to process request and generate pin secret
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        // Poll for pending secrets
        let secret = self.poll_for_secret().await?;

        // Submit PIN
        self.submit_pin(&secret, pin).await?;

        // Await phase1 completion
        phase1_handle.await?
    }

    /// Poll the server for pending pairing secrets
    async fn poll_for_secret(&self) -> Result<String> {
        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()?;

        let url = format!("http://{}:47989/pairing/pending", self.host);

        // Poll for up to 10 seconds
        for _ in 0..20 {
            let response = client.get(&url).send().await?;
            let body: serde_json::Value = response.json().await?;

            if let Some(secrets) = body.get("secrets").and_then(|s| s.as_array()) {
                if !secrets.is_empty() {
                    if let Some(secret) = secrets[0].as_str() {
                        return Ok(secret.to_string());
                    }
                }
            }

            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        }

        Err(anyhow!("Timeout waiting for pairing secret"))
    }

    /// Submit PIN to server
    async fn submit_pin(&self, secret: &str, pin: &str) -> Result<()> {
        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()?;

        let url = format!("http://{}:47989/pin/", self.host);

        #[derive(serde::Serialize)]
        struct PinRequest<'a> {
            pin: &'a str,
            secret: &'a str,
        }

        let response = client
            .post(&url)
            .json(&PinRequest { pin, secret })
            .send()
            .await?;

        if !response.status().is_success() {
            let body = response.text().await?;
            return Err(anyhow!("Failed to submit PIN: {}", body));
        }

        Ok(())
    }

    async fn phase2(&mut self) -> Result<()> {
        // Generate client challenge
        self.client_challenge = vec![0u8; 16];
        rand::thread_rng().fill_bytes(&mut self.client_challenge);

        // Encrypt challenge with AES-ECB
        let encrypted = Self::aes_encrypt_ecb(&self.client_challenge, &self.aes_key)?;

        let url = format!(
            "http://{}:47989/pair?uniqueid={}&uuid={}&devicename=moonlight-mcp&updateState=1&phrase=clientchallenge&clientchallenge={}",
            self.host,
            self.unique_id,
            uuid::Uuid::new_v4(),
            hex::encode(&encrypted)
        );

        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()?;

        let response = client.get(&url).send().await?;
        let body = response.text().await?;

        // Parse challengeresponse
        if let Some(start) = body.find("<challengeresponse>") {
            if let Some(end) = body.find("</challengeresponse>") {
                let challenge_hex = &body[start + 19..end];
                let encrypted_response = hex::decode(challenge_hex)?;
                let decrypted = Self::aes_decrypt_ecb(&encrypted_response, &self.aes_key)?;

                // Server challenge is the last 16 bytes
                if decrypted.len() >= 16 {
                    self.server_challenge = decrypted[decrypted.len() - 16..].to_vec();
                    return Ok(());
                }
            }
        }

        Err(anyhow!("Invalid phase 2 response: {}", body))
    }

    async fn phase3(&mut self) -> Result<()> {
        // Generate client secret
        self.client_secret = vec![0u8; 16];
        rand::thread_rng().fill_bytes(&mut self.client_secret);

        // Get client cert signature
        let cert_der = pem::parse(&self.identity.cert_pem)?.into_contents();
        let (_, cert) = x509_parser::parse_x509_certificate(&cert_der)?;
        let cert_signature = cert.signature_value.as_ref();

        // Create hash: SHA256(server_challenge + cert_signature + client_secret)
        let mut hasher = Sha256::new();
        hasher.update(&self.server_challenge);
        hasher.update(cert_signature);
        hasher.update(&self.client_secret);
        let client_hash = hasher.finalize().to_vec();

        // Encrypt the hash
        let encrypted = Self::aes_encrypt_ecb(&client_hash, &self.aes_key)?;

        let url = format!(
            "http://{}:47989/pair?uniqueid={}&uuid={}&devicename=moonlight-mcp&updateState=1&phrase=serverchallengeresp&serverchallengeresp={}",
            self.host,
            self.unique_id,
            uuid::Uuid::new_v4(),
            hex::encode(&encrypted)
        );

        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()?;

        let response = client.get(&url).send().await?;
        let body = response.text().await?;

        if body.contains("<paired>1</paired>") {
            return Ok(());
        }

        Err(anyhow!("Invalid phase 3 response: {}", body))
    }

    async fn phase4(&self) -> Result<()> {
        // Sign the client secret with our private key
        let key_der = pem::parse(&self.identity.key_pem)?.into_contents();
        let private_key = rsa::RsaPrivateKey::from_pkcs8_der(&key_der)?;
        let signing_key = SigningKey::<Sha256>::new(private_key);
        let signature = signing_key.sign(&self.client_secret);

        // Pairing secret = client_secret + signature
        let mut pairing_secret = self.client_secret.clone();
        pairing_secret.extend(signature.to_bytes().as_ref());

        let url = format!(
            "http://{}:47989/pair?uniqueid={}&uuid={}&devicename=moonlight-mcp&updateState=1&phrase=clientpairingsecret&clientpairingsecret={}",
            self.host,
            self.unique_id,
            uuid::Uuid::new_v4(),
            hex::encode(&pairing_secret)
        );

        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()?;

        let response = client.get(&url).send().await?;
        let body = response.text().await?;

        if body.contains("<paired>1</paired>") {
            return Ok(());
        }

        Err(anyhow!("Pairing failed in phase 4: {}", body))
    }

    fn aes_encrypt_ecb(plaintext: &[u8], key: &[u8]) -> Result<Vec<u8>> {
        let cipher = Aes128::new_from_slice(key)?;
        let mut ciphertext = Vec::new();

        // Pad to block size
        let block_size = 16;
        let mut padded = plaintext.to_vec();
        while padded.len() % block_size != 0 {
            padded.push(0);
        }

        for chunk in padded.chunks(block_size) {
            let mut block = aes::cipher::generic_array::GenericArray::clone_from_slice(chunk);
            cipher.encrypt_block(&mut block);
            ciphertext.extend_from_slice(&block);
        }

        Ok(ciphertext)
    }

    fn aes_decrypt_ecb(ciphertext: &[u8], key: &[u8]) -> Result<Vec<u8>> {
        let cipher = Aes128::new_from_slice(key)?;
        let mut plaintext = Vec::new();

        let block_size = 16;
        for chunk in ciphertext.chunks(block_size) {
            let mut block = aes::cipher::generic_array::GenericArray::clone_from_slice(chunk);
            cipher.decrypt_block(&mut block);
            plaintext.extend_from_slice(&block);
        }

        Ok(plaintext)
    }
}

/// Pair with host using the native protocol
pub async fn native_pair(host: &str, pin: &str) -> Result<()> {
    let mut session = PairingSession::new(host)?;
    session.pair(pin).await
}

/// Check if we have a valid client identity
pub fn has_identity() -> bool {
    ClientIdentity::load_or_create().is_ok()
}

/// Create an mTLS client using our client certificate
fn create_mtls_client() -> Result<reqwest::Client> {
    let client_identity = ClientIdentity::load_or_create()?;
    
    // Create reqwest identity from cert + key PEM (native-tls uses from_pkcs8_pem)
    let identity = reqwest::Identity::from_pkcs8_pem(
        client_identity.cert_pem.as_bytes(),
        client_identity.key_pem.as_bytes(),
    )?;
    
    let client = reqwest::Client::builder()
        .identity(identity)
        .danger_accept_invalid_certs(true) // Server uses self-signed cert
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(30))
        // Force HTTP/1.1 only and disable pooling/proxy for debugging
        .pool_idle_timeout(std::time::Duration::from_secs(0))
        .pool_max_idle_per_host(0)
        .no_proxy()
        .build()?;
    
    Ok(client)
}

/// App info returned from /applist
#[derive(Debug, Clone)]
pub struct AppInfo {
    pub id: u32,
    pub title: String,
}

/// List apps on the host using native HTTPS API
pub async fn native_list_apps(host: &str) -> Result<Vec<AppInfo>> {
    let client = create_mtls_client()?;
    
    // Use fingerprint as uniqueid for consistent identity with Wolf
    let identity = ClientIdentity::load_or_create()?;
    
    let url = format!(
        "https://{}:47984/applist?uniqueid={}&uuid={}",
        host,
        identity.fingerprint,
        uuid::Uuid::new_v4()
    );
    
    let response = client.get(&url).send().await?;
    let body = response.text().await?;
    
    // Parse XML response for apps
    let mut apps = Vec::new();
    
    // Simple XML parsing for <App><ID>N</ID><AppTitle>Name</AppTitle></App>
    let mut pos = 0;
    while let Some(app_start) = body[pos..].find("<App>") {
        let app_start = pos + app_start;
        if let Some(app_end) = body[app_start..].find("</App>") {
            let app_xml = &body[app_start..app_start + app_end + 6];
            
            // Extract ID
            let id = if let Some(id_start) = app_xml.find("<ID>") {
                if let Some(id_end) = app_xml.find("</ID>") {
                    app_xml[id_start + 4..id_end].parse().unwrap_or(0)
                } else { 0 }
            } else { 0 };
            
            // Extract title
            let title = if let Some(title_start) = app_xml.find("<AppTitle>") {
                if let Some(title_end) = app_xml.find("</AppTitle>") {
                    app_xml[title_start + 10..title_end].to_string()
                } else { String::new() }
            } else { String::new() };
            
            if id > 0 && !title.is_empty() {
                apps.push(AppInfo { id, title });
            }
            
            pos = app_start + app_end + 6;
        } else {
            break;
        }
    }
    
    Ok(apps)
}

/// Launch an app on the host using native HTTPS API
pub async fn native_launch(host: &str, app_id: u32) -> Result<String> {
    eprintln!("[DEBUG] native_launch: creating mTLS client...");
    let client = create_mtls_client()?;
    eprintln!("[DEBUG] native_launch: mTLS client created successfully");
    
    // Test: Make a simple request to applist first to check connection
    let test_url = format!(
        "https://{}:47984/applist?uniqueid=test&uuid=test123",
        host
    );
    eprintln!("[DEBUG] native_launch: testing connection with applist...");
    let test_response = client.get(&test_url).send().await?;
    let test_status = test_response.status();
    eprintln!("[DEBUG] native_launch: applist test response status: {}", test_status);
    
    // Generate rikey (AES key for stream encryption) - 16 bytes hex encoded
    let mut rikey = [0u8; 16];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut rikey);
    let rikey_hex = hex::encode(&rikey).to_uppercase();
    
    // Generate rikey ID
    let rikeyid: u32 = rand::random();
    
    // Load client identity to get the certificate fingerprint as uniqueid
    // Wolf requires the uniqueid to match the paired client's cert fingerprint
    let client_identity = ClientIdentity::load_or_create()?;
    let config_dir = dirs::config_dir().ok_or_else(|| anyhow!("No config directory"))?;
    let cert_path = config_dir.join("moonlight-mcp").join("client.crt");
    let key_path = config_dir.join("moonlight-mcp").join("client.key");
    
    // Use the client certificate fingerprint as uniqueid (required for Wolf pairing)
    let uniqueid = &client_identity.fingerprint;
    
    let uuid_val = uuid::Uuid::new_v4().to_string();
    let url = format!(
        "https://{}:47984/launch?uniqueid={}&uuid={}&appid={}&mode=1920x1080x60&additionalStates=1&sops=0&rikey={}&rikeyid={}&localAudioPlayMode=0&surroundAudioInfo=196610",
        host,
        uniqueid,
        uuid_val,
        app_id,
        rikey_hex,
        rikeyid
    );
    eprintln!("[DEBUG] native_launch: calling curl with fingerprint uniqueid: {}", uniqueid);
    eprintln!("[DEBUG] native_launch: URL: {}", url);
    
    // Use curl with long timeout - server can take 45+ seconds to process launch
    let output = tokio::process::Command::new("curl")
        .args(&[
            "-sk",
            "--cert", cert_path.to_str().unwrap(),
            "--key", key_path.to_str().unwrap(),
            "--connect-timeout", "30",
            "--max-time", "90",
            &url
        ])
        .output()
        .await?;
    
    let body = String::from_utf8_lossy(&output.stdout).to_string();
    eprintln!("[DEBUG] native_launch: curl response: {}", body);
    
    // Extract session URL from response
    let session_url = if let Some(start) = body.find("<sessionUrl0>") {
        if let Some(end) = body.find("</sessionUrl0>") {
            Some(body[start + 13..end].to_string())
        } else {
            None
        }
    } else {
        None
    };
    
    // Check for success
    if body.contains("<gamesession>1</gamesession>") || body.contains("status_code=\"200\"") {
        return Ok(session_url.unwrap_or_default());
    }
    
    // Check for errors
    if body.contains("status_code=\"4") || body.contains("status_code=\"5") {
        return Err(anyhow!("Launch failed: {}", body));
    }
    
    // Assume success if no obvious error
    Ok(session_url.unwrap_or_default())
}

/// Verify stream is actually running by checking Wolf's session status
pub async fn native_verify_stream(host: &str) -> Result<StreamStatus> {
    let client = create_mtls_client()?;
    
    // Query the wolf-agent's session list
    let url = format!("https://{}:47984/api/v1/sessions", host);
    
    let response = client.get(&url).send().await?;
    let status_code = response.status();
    let body = response.text().await?;
    eprintln!("[DEBUG] verify_stream: sessions response ({}): {}", status_code, body);
    
    // Handle non-success status codes
    if !status_code.is_success() {
        return Ok(StreamStatus {
            active: false,
            session_count: 0,
            error: Some(format!("Wolf API returned {}: {}", status_code, body.chars().take(100).collect::<String>())),
        });
    }
    
    // Try to parse the JSON response
    match serde_json::from_str::<serde_json::Value>(&body) {
        Ok(sessions) => {
            if let Some(sessions_array) = sessions.get("sessions").and_then(|s| s.as_array()) {
                if sessions_array.is_empty() {
                    return Ok(StreamStatus {
                        active: false,
                        session_count: 0,
                        error: Some("No active sessions found".to_string()),
                    });
                }
                
                // Check if any session is running
                let active_count = sessions_array.len();
                return Ok(StreamStatus {
                    active: active_count > 0,
                    session_count: active_count,
                    error: None,
                });
            }
            
            Ok(StreamStatus {
                active: false,
                session_count: 0,
                error: Some("Sessions response missing 'sessions' array".to_string()),
            })
        }
        Err(_) => {
            // Response was not JSON - provide clear error
            Ok(StreamStatus {
                active: false,
                session_count: 0,
                error: Some(format!("Wolf API returned non-JSON response: {}", body.chars().take(100).collect::<String>())),
            })
        }
    }
}

#[derive(Debug, Clone)]
pub struct StreamStatus {
    pub active: bool,
    pub session_count: usize,
    pub error: Option<String>,
}

/// Quit/stop the current streaming session
pub async fn native_quit(host: &str) -> Result<()> {
    let client = create_mtls_client()?;
    let identity = ClientIdentity::load_or_create()?;
    
    let url = format!(
        "https://{}:47984/cancel?uniqueid={}&uuid={}",
        host,
        identity.fingerprint,
        uuid::Uuid::new_v4()
    );
    
    let response = client.get(&url).send().await?;
    let body = response.text().await?;
    
    if body.contains("cancel=\"1\"") || body.contains("status_code=\"200\"") {
        Ok(())
    } else {
        Err(anyhow!("Failed to quit session: {}", body))
    }
}

/// Send keyboard input to the stream
/// Uses the Wolf/Sunshine input API
pub async fn send_keyboard_input(host: &str, key: &str, action: &str) -> Result<()> {
    let client = create_mtls_client()?;
    
    // Map key names to virtual key codes (subset for common keys)
    let vk_code = match key.to_lowercase().as_str() {
        "enter" | "return" => 0x0D,
        "escape" | "esc" => 0x1B,
        "space" => 0x20,
        "backspace" => 0x08,
        "tab" => 0x09,
        "up" => 0x26,
        "down" => 0x28,
        "left" => 0x25,
        "right" => 0x27,
        "a" => 0x41, "b" => 0x42, "c" => 0x43, "d" => 0x44,
        "e" => 0x45, "f" => 0x46, "g" => 0x47, "h" => 0x48,
        "i" => 0x49, "j" => 0x4A, "k" => 0x4B, "l" => 0x4C,
        "m" => 0x4D, "n" => 0x4E, "o" => 0x4F, "p" => 0x50,
        "q" => 0x51, "r" => 0x52, "s" => 0x53, "t" => 0x54,
        "u" => 0x55, "v" => 0x56, "w" => 0x57, "x" => 0x58,
        "y" => 0x59, "z" => 0x5A,
        "0" => 0x30, "1" => 0x31, "2" => 0x32, "3" => 0x33,
        "4" => 0x34, "5" => 0x35, "6" => 0x36, "7" => 0x37,
        "8" => 0x38, "9" => 0x39,
        "f1" => 0x70, "f2" => 0x71, "f3" => 0x72, "f4" => 0x73,
        "f5" => 0x74, "f6" => 0x75, "f7" => 0x76, "f8" => 0x77,
        "f9" => 0x78, "f10" => 0x79, "f11" => 0x7A, "f12" => 0x7B,
        "ctrl" | "control" => 0x11,
        "alt" => 0x12,
        "shift" => 0x10,
        _ => return Err(anyhow!("Unknown key: {}", key)),
    };
    
    // Wolf input API endpoint
    let url = format!("https://{}:47984/input", host);
    
    #[derive(serde::Serialize)]
    struct KeyboardInput {
        #[serde(rename = "type")]
        input_type: String,
        key_code: u32,
        action: String,  // "down", "up"
    }
    
    match action {
        "tap" => {
            // Send key down then key up
            let down = KeyboardInput {
                input_type: "keyboard".into(),
                key_code: vk_code,
                action: "down".into(),
            };
            let up = KeyboardInput {
                input_type: "keyboard".into(),
                key_code: vk_code,
                action: "up".into(),
            };
            
            client.post(&url).json(&down).send().await?;
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            client.post(&url).json(&up).send().await?;
        }
        "press" | "down" => {
            let input = KeyboardInput {
                input_type: "keyboard".into(),
                key_code: vk_code,
                action: "down".into(),
            };
            client.post(&url).json(&input).send().await?;
        }
        "release" | "up" => {
            let input = KeyboardInput {
                input_type: "keyboard".into(),
                key_code: vk_code,
                action: "up".into(),
            };
            client.post(&url).json(&input).send().await?;
        }
        _ => return Err(anyhow!("Unknown key action: {}", action)),
    }
    
    Ok(())
}

/// Send mouse input to the stream
pub async fn send_mouse_input(
    host: &str,
    action: &str,
    x: Option<i32>,
    y: Option<i32>,
    button: Option<&str>,
    scroll_delta: Option<i32>,
) -> Result<()> {
    let client = create_mtls_client()?;
    let url = format!("https://{}:47984/input", host);
    
    #[derive(serde::Serialize)]
    struct MouseInput {
        #[serde(rename = "type")]
        input_type: String,
        action: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        x: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        y: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        button: Option<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        delta: Option<i32>,
    }
    
    let button_code = button.map(|b| match b.to_lowercase().as_str() {
        "left" => 1,
        "right" => 2,
        "middle" => 3,
        _ => 1,
    });
    
    let input = MouseInput {
        input_type: "mouse".into(),
        action: action.to_string(),
        x,
        y,
        button: button_code,
        delta: scroll_delta,
    };
    
    client.post(&url).json(&input).send().await?;
    Ok(())
}

/// Send gamepad/controller input to the stream
pub async fn send_gamepad_input(
    host: &str,
    button: Option<&str>,
    button_action: Option<&str>,
    left_stick_x: Option<i16>,
    left_stick_y: Option<i16>,
    right_stick_x: Option<i16>,
    right_stick_y: Option<i16>,
    left_trigger: Option<u8>,
    right_trigger: Option<u8>,
) -> Result<()> {
    let client = create_mtls_client()?;
    let url = format!("https://{}:47984/input", host);
    
    // Map button names to Xbox-style button flags
    let button_flag = button.map(|b| match b.to_lowercase().as_str() {
        "a" => 0x1000,
        "b" => 0x2000,
        "x" => 0x4000,
        "y" => 0x8000,
        "lb" | "left_bumper" => 0x0100,
        "rb" | "right_bumper" => 0x0200,
        "start" => 0x0010,
        "select" | "back" => 0x0020,
        "left_stick" | "ls" => 0x0040,
        "right_stick" | "rs" => 0x0080,
        "dpad_up" => 0x0001,
        "dpad_down" => 0x0002,
        "dpad_left" => 0x0004,
        "dpad_right" => 0x0008,
        _ => 0,
    });
    
    #[derive(serde::Serialize)]
    struct GamepadInput {
        #[serde(rename = "type")]
        input_type: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        button_flags: Option<u16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        button_action: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        left_stick_x: Option<i16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        left_stick_y: Option<i16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        right_stick_x: Option<i16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        right_stick_y: Option<i16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        left_trigger: Option<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        right_trigger: Option<u8>,
    }
    
    let input = GamepadInput {
        input_type: "gamepad".into(),
        button_flags: button_flag,
        button_action: button_action.map(|s| s.to_string()),
        left_stick_x,
        left_stick_y,
        right_stick_x,
        right_stick_y,
        left_trigger,
        right_trigger,
    };
    
    client.post(&url).json(&input).send().await?;
    Ok(())
}

/// Capture a frame from an RTSP video stream using ffmpeg
/// This captures the actual Moonlight stream output, not a desktop screenshot
pub async fn capture_rtsp_frame(rtsp_url: &str, output_path: &str, timeout_secs: u32) -> Result<()> {
    eprintln!("[DEBUG] Capturing frame from RTSP stream: {}", rtsp_url);
    
    // Use ffmpeg to grab a single frame from the RTSP stream
    // -rtsp_transport tcp: Use TCP for RTSP (more reliable)
    // -i: Input URL
    // -frames:v 1: Capture only 1 video frame
    // -y: Overwrite output file
    let output = tokio::process::Command::new("ffmpeg")
        .args(&[
            "-rtsp_transport", "tcp",
            "-t", &timeout_secs.to_string(),  // Max time to wait for stream
            "-i", rtsp_url,
            "-frames:v", "1",
            "-q:v", "2",  // High quality JPEG
            "-y",  // Overwrite
            output_path,
        ])
        .output()
        .await?;
    
    if output.status.success() {
        eprintln!("[DEBUG] RTSP frame captured to: {}", output_path);
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // Check for common RTSP errors
        if stderr.contains("Connection refused") {
            Err(anyhow!("RTSP connection refused - stream not available"))
        } else if stderr.contains("Connection timed out") || stderr.contains("timeout") {
            Err(anyhow!("RTSP connection timeout - stream may not be sending video"))
        } else if stderr.contains("Invalid data found") {
            Err(anyhow!("RTSP stream has invalid video data - encoder may have failed"))
        } else if stderr.contains("does not contain any stream") {
            Err(anyhow!("RTSP stream has no video - streaming pipeline may have crashed"))
        } else {
            Err(anyhow!("Failed to capture RTSP frame: {}", stderr.chars().take(500).collect::<String>()))
        }
    }
}

/// Capture a screenshot using macOS screencapture (fallback for non-streaming tests)
pub async fn capture_screenshot(output_path: &str) -> Result<()> {
    let output = tokio::process::Command::new("screencapture")
        .args(&["-x", output_path])
        .output()
        .await?;
    
    if output.status.success() {
        eprintln!("[DEBUG] Screenshot saved to: {}", output_path);
        Ok(())
    } else {
        Err(anyhow!("Failed to capture screenshot: {}", String::from_utf8_lossy(&output.stderr)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_aes_key_derivation() {
        let salt = vec![0u8; 16];
        let pin = "1234";
        let key = PairingSession::derive_aes_key(&salt, pin);
        assert_eq!(key.len(), 16);
    }

    #[test]
    fn test_aes_roundtrip() {
        let key = vec![0u8; 16];
        let plaintext = b"Hello, World!!!"; // 16 bytes
        
        let encrypted = PairingSession::aes_encrypt_ecb(plaintext, &key).unwrap();
        let decrypted = PairingSession::aes_decrypt_ecb(&encrypted, &key).unwrap();
        
        assert_eq!(&decrypted[..16], plaintext);
    }
}
