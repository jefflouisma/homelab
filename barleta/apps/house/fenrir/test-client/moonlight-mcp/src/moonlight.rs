//! Moonlight CLI wrapper module
//!
//! Wraps the Moonlight macOS application CLI for headless operations

use anyhow::{anyhow, Result};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::time::{timeout, Duration};

/// Path to Moonlight CLI on macOS
const MOONLIGHT_CLI: &str = "/Applications/Moonlight.app/Contents/MacOS/Moonlight";

/// List available apps on host
pub async fn list_apps(host: &str) -> Result<Vec<String>> {
    let output = Command::new(MOONLIGHT_CLI)
        .args(["list", host, "--verbose"])
        .output()
        .await?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!("Failed to list apps: {}", stderr));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut apps = Vec::new();
    let mut found_loading = false;

    for line in stdout.lines() {
        let line = line.trim();
        if line.contains("Loading app list") {
            found_loading = true;
            continue;
        }
        if found_loading && !line.is_empty() {
            // Filter out status messages
            if !line.contains("Redirecting")
                && !line.contains("Establishing")
                && !line.contains("Loading")
            {
                apps.push(line.to_string());
            }
        }
    }

    Ok(apps)
}

/// Pair with host using PIN
pub async fn pair(host: &str, pin: &str) -> Result<()> {
    let output = Command::new(MOONLIGHT_CLI)
        .args(["pair", host, "--pin", pin])
        .output()
        .await?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!("Failed to pair: {}", stderr));
    }

    Ok(())
}

/// Quit running app on host
pub async fn quit(host: &str) -> Result<()> {
    let output = Command::new(MOONLIGHT_CLI)
        .args(["quit", host])
        .output()
        .await?;

    if !output.status.success() {
        // Quit errors are often benign
        eprintln!(
            "Quit warning: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    Ok(())
}

/// Stream result with captured screenshot
pub struct StreamResult {
    pub screenshot_path: String,
    pub success: bool,
    pub duration_ms: u64,
}

/// Start streaming an app and capture screenshot after delay
pub async fn stream_and_capture(
    host: &str,
    app: &str,
    capture_after_ms: u64,
    screenshot_dir: &str,
) -> Result<StreamResult> {
    use std::time::Instant;
    use tokio::fs;

    // Create screenshot directory
    fs::create_dir_all(screenshot_dir).await?;

    let start = Instant::now();

    // Start stream process
    let mut child = Command::new(MOONLIGHT_CLI)
        .args([
            "stream",
            host,
            app,
            "--display-mode",
            "windowed",
            "--720",
            "--fps",
            "30",
            "--no-vsync",
            "--no-audio-on-host",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    // Wait for stream to stabilize
    tokio::time::sleep(Duration::from_millis(capture_after_ms)).await;

    // Capture screenshot using macOS screencapture
    let screenshot_path = format!("{}/stream_capture.png", screenshot_dir);
    let capture_result = Command::new("screencapture")
        .args(["-x", &screenshot_path])
        .output()
        .await;

    let success = capture_result.is_ok() && std::path::Path::new(&screenshot_path).exists();

    // Kill the stream
    let _ = child.kill().await;

    // Also quit via Moonlight CLI
    tokio::time::sleep(Duration::from_millis(500)).await;
    let _ = quit(host).await;

    let duration_ms = start.elapsed().as_millis() as u64;

    Ok(StreamResult {
        screenshot_path,
        success,
        duration_ms,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_moonlight_cli_exists() {
        assert!(
            std::path::Path::new(MOONLIGHT_CLI).exists(),
            "Moonlight CLI not found"
        );
    }
}
