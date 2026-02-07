//! JSON test runner module
//!
//! Runs E2E tests defined in JSON format.
//! Provides Moonlight client capabilities that can be composed via JSON test definitions.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::{Mutex, OnceLock};

use crate::control_stream::ControlStream;
use crate::pairing;

/// JSON test definition - the source of truth for test configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestDefinition {
    /// Host address (e.g., "192.168.1.223")
    pub host: String,

    /// Actions to perform (can be a single action or a sequence)
    #[serde(flatten)]
    pub action: TestAction,

    /// App name (for stream tests)
    #[serde(default)]
    pub app: Option<String>,

    /// Timeout in milliseconds
    #[serde(default = "default_timeout")]
    pub timeout_ms: u64,

    /// Delay before validation (ms)
    #[serde(default = "default_delay")]
    pub delay_ms: u64,

    /// Directory to save screenshots (defaults to /tmp)
    #[serde(default = "default_screenshot_dir")]
    pub screenshot_dir: String,

    /// Validation configuration
    #[serde(default)]
    pub validation: ValidationConfig,
}

fn default_timeout() -> u64 {
    60000
}
fn default_delay() -> u64 {
    5000
}
fn default_screenshot_dir() -> String {
    "/tmp".to_string()
}

static LAST_SESSION_URL: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn set_last_session_url(url: &str) {
    let lock = LAST_SESSION_URL.get_or_init(|| Mutex::new(None));
    let mut last = lock.lock().expect("last session url lock poisoned");
    *last = Some(url.to_string());
}

fn last_session_host() -> Option<String> {
    let lock = LAST_SESSION_URL.get_or_init(|| Mutex::new(None));
    let last = lock.lock().expect("last session url lock poisoned");
    last.as_deref().and_then(extract_rtsp_host)
}

fn extract_rtsp_host(url: &str) -> Option<String> {
    let stripped = url.strip_prefix("rtsp://").unwrap_or(url);
    let host_port = stripped.split('/').next().unwrap_or("");
    let host = host_port.split(':').next().unwrap_or("");
    if host.is_empty() {
        None
    } else {
        Some(host.to_string())
    }
}

/// Test actions - these map to Moonlight client capabilities
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum TestAction {
    /// List available apps on the host
    ListApps,

    /// Start streaming an app and optionally verify
    TestStream {
        /// Whether to verify video frames are received
        #[serde(default)]
        verify_video: bool,
        /// Milliseconds to wait for app startup before verification
        #[serde(default = "default_delay")]
        capture_after_ms: u64,
        /// Whether to use the encrypted control stream (like real Moonlight)
        /// When true, connects ENet control channel with AES-128 GCM encryption
        #[serde(default)]
        use_control_stream: bool,
    },

    /// Pair with host using PIN
    Pair { pin: String },

    /// Quit/stop the current streaming session
    Quit,

    /// Send keyboard input
    SendKeyboard {
        /// Key to send (e.g., "enter", "escape", "a", "space")
        key: String,
        /// Key action: "press", "release", or "tap" (press + release)
        #[serde(default = "default_key_action")]
        key_action: String,
    },

    /// Send mouse input
    SendMouse {
        /// Mouse action: "move", "click", "scroll"
        mouse_action: String,
        /// X coordinate (for move/click)
        #[serde(default)]
        x: Option<i32>,
        /// Y coordinate (for move/click)
        #[serde(default)]
        y: Option<i32>,
        /// Mouse button: "left", "right", "middle" (for click)
        #[serde(default)]
        button: Option<String>,
        /// Scroll delta (for scroll)
        #[serde(default)]
        scroll_delta: Option<i32>,
    },

    /// Send gamepad/controller input
    SendGamepad {
        /// Button to press (e.g., "a", "b", "x", "y", "start", "select", "lb", "rb")
        #[serde(default)]
        button: Option<String>,
        /// Button action: "press", "release", or "tap"
        #[serde(default)]
        button_action: Option<String>,
        /// Left stick X axis (-32768 to 32767)
        #[serde(default)]
        left_stick_x: Option<i16>,
        /// Left stick Y axis
        #[serde(default)]
        left_stick_y: Option<i16>,
        /// Right stick X axis
        #[serde(default)]
        right_stick_x: Option<i16>,
        /// Right stick Y axis
        #[serde(default)]
        right_stick_y: Option<i16>,
        /// Left trigger (0-255)
        #[serde(default)]
        left_trigger: Option<u8>,
        /// Right trigger (0-255)
        #[serde(default)]
        right_trigger: Option<u8>,
    },

    /// Wait for a specified duration
    Wait {
        /// Milliseconds to wait
        ms: u64,
    },

    /// Verify stream is active and receiving frames
    VerifyStream,

    /// Run a sequence of actions
    Sequence {
        /// List of actions to run in order
        steps: Vec<TestDefinition>,
    },
}

fn default_key_action() -> String {
    "tap".into()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ValidationConfig {
    /// Expected keywords to find in visual validation
    #[serde(default)]
    pub expect_visible: Vec<String>,

    /// Expect no connection errors
    #[serde(default)]
    pub expect_no_errors: bool,

    /// Expect stream to be active (receiving video)
    #[serde(default)]
    pub expect_stream_active: bool,

    /// Minimum frames per second (if verifying video)
    #[serde(default)]
    pub min_fps: Option<u32>,
}

/// Test result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestResult {
    pub passed: bool,
    pub steps: Vec<StepResult>,
    pub duration_ms: u64,
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
    tokio::fs::create_dir_all(&test.screenshot_dir).await?;
    let result = match tokio::time::timeout(
        std::time::Duration::from_millis(test.timeout_ms),
        run_test(&test),
    )
    .await
    {
        Ok(result) => result?,
        Err(_) => anyhow::bail!("Test timed out after {}ms", test.timeout_ms),
    };

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

    match &test.action {
        TestAction::ListApps => match pairing::native_list_apps(&test.host).await {
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
        },

        TestAction::TestStream {
            verify_video,
            capture_after_ms,
            use_control_stream,
        } => {
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
                                message: format!(
                                    "Found '{}' (id: {}) in app list",
                                    app_info.title, app_info.id
                                ),
                            });

                            // Step 2: Launch the app
                            match pairing::native_launch(&test.host, app_info.id).await {
                                Ok(launch_info) => {
                                    let session_url = &launch_info.session_url;
                                    let has_rtsp = !session_url.is_empty();
                                    if has_rtsp {
                                        set_last_session_url(session_url);
                                    }
                                    steps.push(StepResult {
                                        name: "launch".into(),
                                        passed: true,
                                        message: format!(
                                            "Successfully launched '{}'{}",
                                            app_info.title,
                                            if has_rtsp {
                                                format!(" (RTSP: {})", session_url)
                                            } else {
                                                String::new()
                                            }
                                        ),
                                    });

                                    // Step 2.5: Connect control stream if enabled (like real Moonlight)
                                    let mut control_stream_handle: Option<ControlStream> = None;
                                    if *use_control_stream {
                                        // ENet control port is always 47999 (fixed port in Wolf/Moonlight protocol)
                                        // The RTSP port calculation was incorrect - Wolf uses a fixed ENet port
                                        let control_port = 47999u16;
                                        
                                        eprintln!(
                                            "[DEBUG] Connecting control stream to {}:{} with rikey={}",
                                            test.host, control_port, launch_info.rikey
                                        );
                                        
                                        match ControlStream::connect(
                                            &test.host,
                                            control_port,
                                            &launch_info.rikey,
                                            launch_info.rikeyid,
                                        ).await {
                                            Ok(mut cs) => {
                                                // Test the control stream with pings
                                                match cs.test_connection().await {
                                                    Ok(()) => {
                                                        steps.push(StepResult {
                                                            name: "control_stream".into(),
                                                            passed: true,
                                                            message: format!(
                                                                "Control stream connected and pings sent (port: {})",
                                                                control_port
                                                            ),
                                                        });
                                                        control_stream_handle = Some(cs);
                                                    }
                                                    Err(e) => {
                                                        steps.push(StepResult {
                                                            name: "control_stream".into(),
                                                            passed: false,
                                                            message: format!(
                                                                "Control stream ping failed: {} (this may indicate AES-GCM encryption issues)",
                                                                e
                                                            ),
                                                        });
                                                    }
                                                }
                                            }
                                            Err(e) => {
                                                steps.push(StepResult {
                                                    name: "control_stream".into(),
                                                    passed: false,
                                                    message: format!("Failed to connect control stream: {}", e),
                                                });
                                            }
                                        }
                                    }

                                    // Wait for app to start
                                    tokio::time::sleep(std::time::Duration::from_millis(
                                        *capture_after_ms,
                                    ))
                                    .await;
                                    steps.push(StepResult {
                                        name: "wait_startup".into(),
                                        passed: true,
                                        message: format!(
                                            "Waited {}ms for app startup",
                                            capture_after_ms
                                        ),
                                    });

                                    // Step 3: Verify stream via API (optional, just for diagnostics)
                                    if *verify_video {
                                        let verify_host = extract_rtsp_host(&session_url)
                                            .unwrap_or_else(|| test.host.clone());
                                        match pairing::native_verify_stream(&verify_host).await {
                                            Ok(status) => {
                                                steps.push(StepResult {
                                                    name: "verify_stream_api".into(),
                                                    passed: status.active,
                                                    message: if status.active {
                                                        format!(
                                                            "Wolf API: {} active session(s)",
                                                            status.session_count
                                                        )
                                                    } else {
                                                        format!(
                                                            "Wolf API: {}",
                                                            status.error.unwrap_or_else(|| {
                                                                "no active sessions".into()
                                                            })
                                                        )
                                                    },
                                                });
                                            }
                                            Err(e) => {
                                                steps.push(StepResult {
                                                    name: "verify_stream_api".into(),
                                                    passed: false,
                                                    message: format!(
                                                        "Wolf API check failed: {}",
                                                        e
                                                    ),
                                                });
                                            }
                                        }
                                    }

                                    // Step 4: MANDATORY - Capture frame from RTSP stream and validate with Gemini vision
                                    let screenshot_path = format!(
                                        "{}/moonlight_stream_{}.png",
                                        test.screenshot_dir,
                                        std::process::id()
                                    );

                                    // Use RTSP capture if we have a session URL, otherwise fallback to desktop screenshot
                                    let capture_result = if has_rtsp {
                                        pairing::capture_rtsp_frame(
                                            &session_url,
                                            &screenshot_path,
                                            10,
                                        )
                                        .await
                                    } else {
                                        // Fallback to desktop screenshot if no RTSP URL
                                        steps.push(StepResult {
                                            name: "rtsp_unavailable".into(),
                                            passed: false,
                                            message: "No RTSP URL returned - using fallback desktop capture".into(),
                                        });
                                        pairing::capture_screenshot(&screenshot_path).await
                                    };

                                    match capture_result {
                                        Ok(()) => {
                                            steps.push(StepResult {
                                                name: "capture_stream_frame".into(),
                                                passed: true,
                                                message: format!(
                                                    "Stream frame captured: {}",
                                                    screenshot_path
                                                ),
                                            });

                                            // Vision validation with Gemini
                                            match crate::validator::validate_screenshot(
                                                &screenshot_path,
                                                &app_info.title,
                                            )
                                            .await
                                            {
                                                Ok(validation) => {
                                                    let vision_passed = validation.passed
                                                        && validation.streaming_active;
                                                    steps.push(StepResult {
                                                        name: "gemini_vision".into(),
                                                        passed: vision_passed,
                                                        message: format!(
                                                            "Vision: {} | App visible: {} | Streaming: {} | {}",
                                                            if vision_passed { "PASS" } else { "FAIL" },
                                                            validation.app_visible,
                                                            validation.streaming_active,
                                                            validation.description
                                                        ),
                                                    });

                                                    // Add error details if present (skip null/empty)
                                                    if let Some(errors) = validation.error_messages
                                                    {
                                                        let errors_trimmed = errors.trim();
                                                        if !errors_trimmed.is_empty()
                                                            && errors_trimmed != "null"
                                                            && errors_trimmed != "none"
                                                            && errors_trimmed != "N/A"
                                                        {
                                                            steps.push(StepResult {
                                                                name: "vision_errors".into(),
                                                                passed: false,
                                                                message: format!(
                                                                    "Errors detected: {}",
                                                                    errors
                                                                ),
                                                            });
                                                        }
                                                    }
                                                }
                                                Err(e) => {
                                                    steps.push(StepResult {
                                                        name: "gemini_vision".into(),
                                                        passed: false,
                                                        message: format!(
                                                            "Vision validation failed: {}",
                                                            e
                                                        ),
                                                    });
                                                }
                                            }

                                            // Clean up screenshot (optional - keep for debugging)
                                            // let _ = tokio::fs::remove_file(&screenshot_path).await;
                                        }
                                        Err(e) => {
                                            steps.push(StepResult {
                                                name: "capture_stream_frame".into(),
                                                passed: false,
                                                message: format!(
                                                    "Failed to capture stream frame: {}",
                                                    e
                                                ),
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
                            let app_names: Vec<String> =
                                apps.iter().map(|a| a.title.clone()).collect();
                            steps.push(StepResult {
                                name: "find_app".into(),
                                passed: false,
                                message: format!(
                                    "'{}' not found. Available: {}",
                                    app,
                                    app_names.join(", ")
                                ),
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

        TestAction::Pair { pin } => match pairing::native_pair(&test.host, pin).await {
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
        },

        TestAction::Quit => match pairing::native_quit(&test.host).await {
            Ok(()) => {
                steps.push(StepResult {
                    name: "quit".into(),
                    passed: true,
                    message: "Session stopped".into(),
                });
            }
            Err(e) => {
                steps.push(StepResult {
                    name: "quit".into(),
                    passed: false,
                    message: format!("Failed to quit: {}", e),
                });
            }
        },

        TestAction::SendKeyboard { key, key_action } => {
            match pairing::send_keyboard_input(&test.host, key, key_action).await {
                Ok(()) => {
                    steps.push(StepResult {
                        name: "send_keyboard".into(),
                        passed: true,
                        message: format!("Sent keyboard: {} {}", key_action, key),
                    });
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "send_keyboard".into(),
                        passed: false,
                        message: format!("Failed to send keyboard: {}", e),
                    });
                }
            }
        }

        TestAction::SendMouse {
            mouse_action,
            x,
            y,
            button,
            scroll_delta,
        } => {
            match pairing::send_mouse_input(
                &test.host,
                mouse_action,
                *x,
                *y,
                button.as_deref(),
                *scroll_delta,
            )
            .await
            {
                Ok(()) => {
                    steps.push(StepResult {
                        name: "send_mouse".into(),
                        passed: true,
                        message: format!("Sent mouse: {}", mouse_action),
                    });
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "send_mouse".into(),
                        passed: false,
                        message: format!("Failed to send mouse: {}", e),
                    });
                }
            }
        }

        TestAction::SendGamepad {
            button,
            button_action,
            left_stick_x,
            left_stick_y,
            right_stick_x,
            right_stick_y,
            left_trigger,
            right_trigger,
        } => {
            // Map button name to Xbox-style button flags (same as Moonlight protocol)
            let button_flags: u16 = button.as_ref().map(|b| match b.to_lowercase().as_str() {
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
            }).unwrap_or(0);

            // Get session crypto from Wolf API to establish control stream
            match pairing::get_session_crypto(&test.host).await {
                Ok(crypto) => {
                    // Connect to control stream using session's AES key
                    match ControlStream::connect(&test.host, 47999, &crypto.rikey, crypto.rikeyid).await {
                        Ok(mut cs) => {
                            let action = button_action.as_deref().unwrap_or("tap");
                            let result = match action {
                                "tap" => cs.send_gamepad_tap(button_flags).await,
                                "press" | "down" => {
                                    cs.send_gamepad(
                                        button_flags,
                                        left_trigger.unwrap_or(0),
                                        right_trigger.unwrap_or(0),
                                        left_stick_x.unwrap_or(0),
                                        left_stick_y.unwrap_or(0),
                                        right_stick_x.unwrap_or(0),
                                        right_stick_y.unwrap_or(0),
                                    ).await
                                }
                                "release" | "up" => {
                                    // Send zero state (all released)
                                    cs.send_gamepad(0, 0, 0, 0, 0, 0, 0).await
                                }
                                _ => cs.send_gamepad_tap(button_flags).await,
                            };

                            match result {
                                Ok(()) => {
                                    let msg = if let Some(b) = button {
                                        format!("Sent gamepad button '{}' ({}) via control stream", b, action)
                                    } else {
                                        "Sent gamepad analog input via control stream".into()
                                    };
                                    steps.push(StepResult {
                                        name: "send_gamepad".into(),
                                        passed: true,
                                        message: msg,
                                    });
                                }
                                Err(e) => {
                                    steps.push(StepResult {
                                        name: "send_gamepad".into(),
                                        passed: false,
                                        message: format!("Failed to send gamepad via control stream: {}", e),
                                    });
                                }
                            }
                        }
                        Err(e) => {
                            steps.push(StepResult {
                                name: "send_gamepad".into(),
                                passed: false,
                                message: format!("Failed to connect control stream: {}", e),
                            });
                        }
                    }
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "send_gamepad".into(),
                        passed: false,
                        message: format!("Failed to get session crypto: {}", e),
                    });
                }
            }
        }

        TestAction::Wait { ms } => {
            tokio::time::sleep(std::time::Duration::from_millis(*ms)).await;
            steps.push(StepResult {
                name: "wait".into(),
                passed: true,
                message: format!("Waited {}ms", ms),
            });
        }

        TestAction::VerifyStream => {
            let verify_host = last_session_host().unwrap_or_else(|| test.host.clone());
            match pairing::native_verify_stream(&verify_host).await {
                Ok(status) => {
                    if status.active {
                        steps.push(StepResult {
                            name: "verify_stream".into(),
                            passed: true,
                            message: format!("Stream active: {} session(s)", status.session_count),
                        });
                    } else {
                        steps.push(StepResult {
                            name: "verify_stream".into(),
                            passed: false,
                            message: format!(
                                "Stream NOT active: {}",
                                status.error.unwrap_or_else(|| "unknown".into())
                            ),
                        });
                    }
                }
                Err(e) => {
                    steps.push(StepResult {
                        name: "verify_stream".into(),
                        passed: false,
                        message: format!("Could not verify stream: {}", e),
                    });
                }
            }
        }

        TestAction::Sequence {
            steps: sequence_steps,
        } => {
            for (i, step_def) in sequence_steps.iter().enumerate() {
                // Use Box::pin to handle recursive async call
                let step_result = Box::pin(run_test(step_def)).await?;
                for s in step_result.steps {
                    steps.push(StepResult {
                        name: format!("step_{}.{}", i + 1, s.name),
                        passed: s.passed,
                        message: s.message,
                    });
                }
                // Stop sequence if a step fails
                if !step_result.passed {
                    break;
                }
            }
        }
    }

    let passed = steps.iter().all(|s| s.passed);

    Ok(TestResult {
        passed,
        steps,
        duration_ms: start.elapsed().as_millis() as u64,
    })
}
