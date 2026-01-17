//! JSON test runner module
//!
//! Runs E2E tests defined in JSON format

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::moonlight;
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
            match moonlight::list_apps(&test.host).await {
                Ok(apps) => {
                    steps.push(StepResult {
                        name: "list_apps".into(),
                        passed: true,
                        message: format!("Found {} apps: {}", apps.len(), apps.join(", ")),
                    });
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "list_apps".into(),
                        passed: false,
                        message: e.to_string(),
                    });
                }
            }
        }

        TestAction::TestStream => {
            let app = test.app.clone().unwrap_or_else(|| "Desktop".into());

            // Step 1: List apps and find target
            match moonlight::list_apps(&test.host).await {
                Ok(apps) => {
                    let found = apps
                        .iter()
                        .any(|a| a.to_lowercase().contains(&app.to_lowercase()));
                    steps.push(StepResult {
                        name: "find_app".into(),
                        passed: found,
                        message: if found {
                            format!("Found '{}' in app list", app)
                        } else {
                            format!("'{}' not found. Available: {}", app, apps.join(", "))
                        },
                    });

                    if !found {
                        return Ok(TestResult {
                            passed: false,
                            steps,
                            duration_ms: start.elapsed().as_millis() as u64,
                            validation: None,
                        });
                    }
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "list_apps".into(),
                        passed: false,
                        message: e.to_string(),
                    });
                    return Ok(TestResult {
                        passed: false,
                        steps,
                        duration_ms: start.elapsed().as_millis() as u64,
                        validation: None,
                    });
                }
            }

            // Step 2: Stream and capture
            let screenshot_dir = "/tmp/moonlight-mcp";
            match moonlight::stream_and_capture(
                &test.host,
                &app,
                test.capture_after_ms,
                screenshot_dir,
            )
            .await
            {
                Ok(result) => {
                    steps.push(StepResult {
                        name: "stream_capture".into(),
                        passed: result.success,
                        message: if result.success {
                            format!("Screenshot captured: {}", result.screenshot_path)
                        } else {
                            "Failed to capture screenshot".into()
                        },
                    });

                    // Step 3: Validate with AI
                    if result.success {
                        match validator::validate_screenshot(&result.screenshot_path, &app).await {
                            Ok(val) => {
                                steps.push(StepResult {
                                    name: "ai_validation".into(),
                                    passed: val.passed,
                                    message: val.description.clone(),
                                });
                                validation = Some(val);
                            }
                            Err(e) => {
                                steps.push(StepResult {
                                    name: "ai_validation".into(),
                                    passed: false,
                                    message: e.to_string(),
                                });
                            }
                        }
                    }
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "stream_capture".into(),
                        passed: false,
                        message: e.to_string(),
                    });
                }
            }
        }

        TestAction::Pair { pin } => {
            match moonlight::pair(&test.host, pin).await {
                Ok(()) => {
                    steps.push(StepResult {
                        name: "pair".into(),
                        passed: true,
                        message: "Successfully paired".into(),
                    });
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "pair".into(),
                        passed: false,
                        message: e.to_string(),
                    });
                }
            }
        }

        TestAction::Quit => {
            match moonlight::quit(&test.host).await {
                Ok(()) => {
                    steps.push(StepResult {
                        name: "quit".into(),
                        passed: true,
                        message: "Successfully quit".into(),
                    });
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "quit".into(),
                        passed: false,
                        message: e.to_string(),
                    });
                }
            }
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
