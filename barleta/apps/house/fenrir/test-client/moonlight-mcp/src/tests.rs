//! JSON test runner module
//!
//! Runs E2E tests defined in JSON format

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::pairing;
use crate::validator;

/// JSON test definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestDefinition {
    /// Host address (e.g., "192.168.1.223")
    pub host: String,

    /// Action to perform
    pub action: TestAction,

    /// App name (for stream tests)
    #[serde(default)]
    pub app: Option<String>,

    /// Timeout in milliseconds
    #[serde(default = "default_timeout")]
    pub timeout_ms: u64,

    /// Delay before capturing screenshot (ms)
    #[serde(default = "default_capture_delay")]
    pub capture_after_ms: u64,

    /// Validation configuration
    #[serde(default)]
    pub validation: ValidationConfig,
}

fn default_timeout() -> u64 {
    60000
}
fn default_capture_delay() -> u64 {
    15000
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TestAction {
    ListApps,
    TestStream,
    Pair { pin: String },
    Quit,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ValidationConfig {
    /// Expected keywords to find
    #[serde(default)]
    pub expect_visible: Vec<String>,

    /// Should not have errors
    #[serde(default)]
    pub expect_no_errors: bool,
}

/// Test result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestResult {
    pub passed: bool,
    pub steps: Vec<StepResult>,
    pub duration_ms: u64,
    pub validation: Option<validator::ValidationResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StepResult {
    pub name: String,
    pub passed: bool,
    pub message: String,
}

/// Run a test from file
pub async fn run_test_file(path: &Path) -> Result<()> {
    let content = tokio::fs::read_to_string(path).await?;
    let test: TestDefinition = serde_json::from_str(&content)?;
    let result = run_test(&test).await?;

    println!("{}", serde_json::to_string_pretty(&result)?);

    if result.passed {
        // Capture screenshot as proof of success
        let timestamp = chrono::Utc::now().format("%Y%m%d_%H%M%S");
        let screenshot_path = format!("e2e_success_{}.png", timestamp);
        match pairing::capture_screenshot(&screenshot_path).await {
            Ok(()) => eprintln!("[SUCCESS] Screenshot saved: {}", screenshot_path),
            Err(e) => eprintln!("[WARNING] Could not capture screenshot: {}", e),
        }
        Ok(())
    } else {
        anyhow::bail!("Test failed")
    }
}

/// Run a test definition
pub async fn run_test(test: &TestDefinition) -> Result<TestResult> {
    use std::time::Instant;

    let start = Instant::now();
    let mut steps = Vec::new();
    let mut validation = None;

    match &test.action {
        TestAction::ListApps => {
            match pairing::native_list_apps(&test.host).await {
                Ok(apps) => {
                    let app_names: Vec<String> = apps.iter().map(|a| a.title.clone()).collect();
                    steps.push(StepResult {
                        name: "list_apps".into(),
                        passed: true,
                        message: format!("Found {} apps: {}", apps.len(), app_names.join(", ")),
                    });
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "list_apps".into(),
                        passed: false,
                        message: format!("Failed to list apps: {}", e),
                    });
                }
            }
        }

        TestAction::TestStream => {
            let app = test.app.clone().unwrap_or_else(|| "Desktop".into());

            // Step 1: List apps and find target
            match pairing::native_list_apps(&test.host).await {
                Ok(apps) => {
                    let found_app = apps
                        .iter()
                        .find(|a| a.title.to_lowercase().contains(&app.to_lowercase()));
                    
                    match found_app {
                        Some(app_info) => {
                            steps.push(StepResult {
                                name: "find_app".into(),
                                passed: true,
                                message: format!("Found '{}' (id: {}) in app list", app_info.title, app_info.id),
                            });
                            
                            // Step 2: Launch the app
                            match pairing::native_launch(&test.host, app_info.id).await {
                                Ok(session_url) => {
                                    steps.push(StepResult {
                                        name: "launch".into(),
                                        passed: true,
                                        message: format!("Successfully launched '{}' (session: {})", app_info.title, session_url),
                                    });
                                    
                                    // Wait for app to start
                                    tokio::time::sleep(std::time::Duration::from_millis(test.capture_after_ms)).await;
                                    
                                    steps.push(StepResult {
                                        name: "wait_for_app".into(),
                                        passed: true,
                                        message: format!("Waited {}ms for app startup", test.capture_after_ms),
                                    });
                                    
                                    // Step 3: Verify stream is actually running
                                    match pairing::native_verify_stream(&test.host).await {
                                        Ok(status) => {
                                            if status.active {
                                                steps.push(StepResult {
                                                    name: "verify_stream".into(),
                                                    passed: true,
                                                    message: format!("Stream verified: {} active session(s)", status.session_count),
                                                });
                                            } else {
                                                steps.push(StepResult {
                                                    name: "verify_stream".into(),
                                                    passed: false,
                                                    message: format!("Stream NOT active: {}", status.error.unwrap_or_else(|| "unknown".into())),
                                                });
                                            }
                                        }
                                        Err(e) => {
                                            // Stream verification is advisory - log but don't fail
                                            steps.push(StepResult {
                                                name: "verify_stream".into(),
                                                passed: false,
                                                message: format!("Could not verify stream: {}", e),
                                            });
                                        }
                                    }
                                }
                                Err(e) => {
                                    steps.push(StepResult {
                                        name: "launch".into(),
                                        passed: false,
                                        message: format!("Failed to launch: {}", e),
                                    });
                                }
                            }
                        }
                        None => {
                            let app_names: Vec<String> = apps.iter().map(|a| a.title.clone()).collect();
                            steps.push(StepResult {
                                name: "find_app".into(),
                                passed: false,
                                message: format!("'{}' not found. Available: {}", app, app_names.join(", ")),
                            });
                        }
                    }
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "list_apps".into(),
                        passed: false,
                        message: format!("Failed to list apps: {}", e),
                    });
                }
            }
        }

        TestAction::Pair { pin } => {
            match pairing::native_pair(&test.host, pin).await {
                Ok(()) => {
                    steps.push(StepResult {
                        name: "pair".into(),
                        passed: true,
                        message: "Successfully paired using native protocol".into(),
                    });
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "pair".into(),
                        passed: false,
                        message: format!("Failed to pair: {}", e),
                    });
                }
            }
        }

        TestAction::Quit => {
            // Quit is a no-op for now since we don't have a native cancel implementation
            steps.push(StepResult {
                name: "quit".into(),
                passed: true,
                message: "Quit action (no-op for native implementation)".into(),
            });
        }
    }

    let passed = steps.iter().all(|s| s.passed);

    Ok(TestResult {
        passed,
        steps,
        duration_ms: start.elapsed().as_millis() as u64,
        validation,
    })
}
