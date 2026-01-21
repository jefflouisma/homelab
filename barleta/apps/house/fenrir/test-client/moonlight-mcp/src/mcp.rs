//! MCP stdio protocol handler
//!
//! Implements the Model Context Protocol for AI agent integration.
//! Exposes Moonlight client capabilities as MCP tools.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::tests::{self, TestAction, TestDefinition, ValidationConfig};

/// JSON-RPC 2.0 Request
#[derive(Debug, Deserialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    id: serde_json::Value,
    method: String,
    #[serde(default)]
    params: serde_json::Value,
}

/// JSON-RPC 2.0 Response
#[derive(Debug, Serialize)]
struct JsonRpcResponse {
    jsonrpc: String,
    id: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<JsonRpcError>,
}

#[derive(Debug, Serialize)]
struct JsonRpcError {
    code: i32,
    message: String,
}

/// MCP Server capabilities
#[derive(Debug, Serialize)]
struct ServerInfo {
    name: String,
    version: String,
}

#[derive(Debug, Serialize)]
struct Capabilities {
    tools: ToolsCapability,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolsCapability {
    list_changed: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct InitializeResult {
    protocol_version: String,
    server_info: ServerInfo,
    capabilities: Capabilities,
}

/// Tool definition
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Tool {
    name: String,
    description: String,
    input_schema: serde_json::Value,
}

/// Tool call result
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolResult {
    content: Vec<ContentItem>,
    is_error: bool,
}

#[derive(Debug, Serialize)]
struct ContentItem {
    #[serde(rename = "type")]
    content_type: String,
    text: String,
}

/// Run MCP stdio server
pub async fn run_mcp_server() -> Result<()> {
    let stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let mut reader = BufReader::new(stdin);

    eprintln!("moonlight-mcp: MCP server started");

    loop {
        let mut line = String::new();
        let bytes_read = reader.read_line(&mut line).await?;

        if bytes_read == 0 {
            break; // EOF
        }

        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // Parse JSON-RPC request
        let request: JsonRpcRequest = match serde_json::from_str(line) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("Failed to parse request: {}", e);
                continue;
            }
        };

        // Handle request
        let response = handle_request(&request).await;

        // Write response
        let response_json = serde_json::to_string(&response)?;
        stdout.write_all(response_json.as_bytes()).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }

    Ok(())
}

async fn handle_request(request: &JsonRpcRequest) -> JsonRpcResponse {
    let result = match request.method.as_str() {
        "initialize" => handle_initialize().await,
        "tools/list" => handle_tools_list().await,
        "tools/call" => handle_tools_call(&request.params).await,
        "ping" => Ok(serde_json::json!({})),
        _ => Err(anyhow::anyhow!("Unknown method: {}", request.method)),
    };

    match result {
        Ok(value) => JsonRpcResponse {
            jsonrpc: "2.0".into(),
            id: request.id.clone(),
            result: Some(value),
            error: None,
        },
        Err(e) => JsonRpcResponse {
            jsonrpc: "2.0".into(),
            id: request.id.clone(),
            result: None,
            error: Some(JsonRpcError {
                code: -32603,
                message: e.to_string(),
            }),
        },
    }
}

async fn handle_initialize() -> Result<serde_json::Value> {
    Ok(serde_json::to_value(InitializeResult {
        protocol_version: "2024-11-05".into(),
        server_info: ServerInfo {
            name: "moonlight-mcp".into(),
            version: env!("CARGO_PKG_VERSION").into(),
        },
        capabilities: Capabilities {
            tools: ToolsCapability {
                list_changed: false,
            },
        },
    })?)
}

async fn handle_tools_list() -> Result<serde_json::Value> {
    let tools = vec![
        // === Discovery & Connection ===
        Tool {
            name: "moonlight_list_apps".into(),
            description: "List available apps on the Fenrir/GameStream host".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "Host address (e.g., 192.168.1.223)"
                    }
                },
                "required": ["host"]
            }),
        },
        Tool {
            name: "moonlight_pair".into(),
            description: "Pair with a GameStream host using PIN".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "Host address"
                    },
                    "pin": {
                        "type": "string",
                        "description": "4-digit PIN code"
                    }
                },
                "required": ["host", "pin"]
            }),
        },
        // === Streaming ===
        Tool {
            name: "moonlight_test_stream".into(),
            description: "Stream an app, capture screenshot, and validate with AI vision".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "Host address"
                    },
                    "app": {
                        "type": "string",
                        "description": "App name to stream (e.g., RetroArch)"
                    },
                    "capture_after_ms": {
                        "type": "integer",
                        "description": "Milliseconds to wait before capturing screenshot",
                        "default": 15000
                    }
                },
                "required": ["host", "app"]
            }),
        },
        Tool {
            name: "moonlight_quit".into(),
            description: "Quit the currently running app on the host".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "Host address"
                    }
                },
                "required": ["host"]
            }),
        },
        Tool {
            name: "moonlight_verify_stream".into(),
            description: "Verify that the stream is active and receiving video".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "Host address"
                    }
                },
                "required": ["host"]
            }),
        },
        // === Input ===
        Tool {
            name: "moonlight_send_keyboard".into(),
            description: "Send keyboard input to the stream".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "Host address"
                    },
                    "key": {
                        "type": "string",
                        "description": "Key to send (e.g., 'enter', 'escape', 'a', 'space', 'f1')"
                    },
                    "action": {
                        "type": "string",
                        "description": "Key action: 'tap' (default), 'press', or 'release'",
                        "default": "tap"
                    }
                },
                "required": ["host", "key"]
            }),
        },
        Tool {
            name: "moonlight_send_mouse".into(),
            description: "Send mouse input to the stream".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "Host address"
                    },
                    "action": {
                        "type": "string",
                        "description": "Mouse action: 'move', 'click', 'scroll'"
                    },
                    "x": {
                        "type": "integer",
                        "description": "X coordinate (for move/click)"
                    },
                    "y": {
                        "type": "integer",
                        "description": "Y coordinate (for move/click)"
                    },
                    "button": {
                        "type": "string",
                        "description": "Mouse button: 'left', 'right', 'middle'"
                    },
                    "scroll_delta": {
                        "type": "integer",
                        "description": "Scroll amount (for scroll action)"
                    }
                },
                "required": ["host", "action"]
            }),
        },
        Tool {
            name: "moonlight_send_gamepad".into(),
            description: "Send gamepad/controller input to the stream".into(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "Host address"
                    },
                    "button": {
                        "type": "string",
                        "description": "Button: 'a', 'b', 'x', 'y', 'lb', 'rb', 'start', 'select', 'dpad_up', etc."
                    },
                    "button_action": {
                        "type": "string",
                        "description": "Button action: 'tap', 'press', 'release'"
                    },
                    "left_stick_x": {
                        "type": "integer",
                        "description": "Left stick X axis (-32768 to 32767)"
                    },
                    "left_stick_y": {
                        "type": "integer",
                        "description": "Left stick Y axis"
                    },
                    "right_stick_x": {
                        "type": "integer",
                        "description": "Right stick X axis"
                    },
                    "right_stick_y": {
                        "type": "integer",
                        "description": "Right stick Y axis"
                    },
                    "left_trigger": {
                        "type": "integer",
                        "description": "Left trigger (0-255)"
                    },
                    "right_trigger": {
                        "type": "integer",
                        "description": "Right trigger (0-255)"
                    }
                },
                "required": ["host"]
            }),
        },
    ];

    Ok(serde_json::json!({ "tools": tools }))
}

async fn handle_tools_call(params: &serde_json::Value) -> Result<serde_json::Value> {
    let name = params["name"].as_str().unwrap_or("");
    let arguments = &params["arguments"];

    let result = match name {
        "moonlight_list_apps" => {
            let host = arguments["host"].as_str().unwrap_or("localhost");
            match crate::pairing::native_list_apps(host).await {
                Ok(apps) => {
                    let app_names: Vec<String> = apps.iter().map(|a| a.title.clone()).collect();
                    ToolResult {
                        content: vec![ContentItem {
                            content_type: "text".into(),
                            text: serde_json::json!({
                                "apps": app_names,
                                "count": apps.len()
                            })
                            .to_string(),
                        }],
                        is_error: false,
                    }
                }
                Err(e) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Error: {}", e),
                    }],
                    is_error: true,
                },
            }
        }

        "moonlight_test_stream" => {
            let host = arguments["host"].as_str().unwrap_or("localhost");
            let app = arguments["app"].as_str().unwrap_or("Desktop");
            let capture_after_ms = arguments["capture_after_ms"].as_u64().unwrap_or(15000);

            let test = TestDefinition {
                host: host.into(),
                action: TestAction::TestStream {
                    verify_video: true,
                    capture_after_ms,
                },
                app: Some(app.into()),
                timeout_ms: 120000,
                delay_ms: 5000,
                screenshot_dir: "/tmp".into(),
                validation: ValidationConfig::default(),
            };

            match tests::run_test(&test).await {
                Ok(result) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: serde_json::to_string_pretty(&result).unwrap_or_default(),
                    }],
                    is_error: !result.passed,
                },
                Err(e) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Error: {}", e),
                    }],
                    is_error: true,
                },
            }
        }

        "moonlight_pair" => {
            let host = arguments["host"].as_str().unwrap_or("localhost");
            let pin = arguments["pin"].as_str().unwrap_or("0000");

            match crate::pairing::native_pair(host, pin).await {
                Ok(()) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: "Successfully paired using native protocol".into(),
                    }],
                    is_error: false,
                },
                Err(e) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Pairing failed: {}", e),
                    }],
                    is_error: true,
                },
            }
        }

        "moonlight_quit" => {
            let host = arguments["host"].as_str().unwrap_or("localhost");

            match crate::pairing::native_quit(host).await {
                Ok(()) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: "Session stopped".into(),
                    }],
                    is_error: false,
                },
                Err(e) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Failed to quit: {}", e),
                    }],
                    is_error: true,
                },
            }
        }

        "moonlight_verify_stream" => {
            let host = arguments["host"].as_str().unwrap_or("localhost");

            match crate::pairing::native_verify_stream(host).await {
                Ok(status) => {
                    let result_json = serde_json::json!({
                        "active": status.active,
                        "session_count": status.session_count,
                        "error": status.error
                    });
                    ToolResult {
                        content: vec![ContentItem {
                            content_type: "text".into(),
                            text: result_json.to_string(),
                        }],
                        is_error: !status.active,
                    }
                }
                Err(e) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Failed to verify stream: {}", e),
                    }],
                    is_error: true,
                },
            }
        }

        "moonlight_send_keyboard" => {
            let host = arguments["host"].as_str().unwrap_or("localhost");
            let key = arguments["key"].as_str().unwrap_or("enter");
            let action = arguments["action"].as_str().unwrap_or("tap");

            match crate::pairing::send_keyboard_input(host, key, action).await {
                Ok(()) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Sent keyboard: {} {}", action, key),
                    }],
                    is_error: false,
                },
                Err(e) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Failed: {}", e),
                    }],
                    is_error: true,
                },
            }
        }

        "moonlight_send_mouse" => {
            let host = arguments["host"].as_str().unwrap_or("localhost");
            let action = arguments["action"].as_str().unwrap_or("click");
            let x = arguments["x"].as_i64().map(|v| v as i32);
            let y = arguments["y"].as_i64().map(|v| v as i32);
            let button = arguments["button"].as_str();
            let scroll_delta = arguments["scroll_delta"].as_i64().map(|v| v as i32);

            match crate::pairing::send_mouse_input(host, action, x, y, button, scroll_delta).await {
                Ok(()) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Sent mouse: {}", action),
                    }],
                    is_error: false,
                },
                Err(e) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Failed: {}", e),
                    }],
                    is_error: true,
                },
            }
        }

        "moonlight_send_gamepad" => {
            let host = arguments["host"].as_str().unwrap_or("localhost");
            let button = arguments["button"].as_str();
            let button_action = arguments["button_action"].as_str();
            let left_stick_x = arguments["left_stick_x"].as_i64().map(|v| v as i16);
            let left_stick_y = arguments["left_stick_y"].as_i64().map(|v| v as i16);
            let right_stick_x = arguments["right_stick_x"].as_i64().map(|v| v as i16);
            let right_stick_y = arguments["right_stick_y"].as_i64().map(|v| v as i16);
            let left_trigger = arguments["left_trigger"].as_u64().map(|v| v as u8);
            let right_trigger = arguments["right_trigger"].as_u64().map(|v| v as u8);

            match crate::pairing::send_gamepad_input(
                host,
                button,
                button_action,
                left_stick_x,
                left_stick_y,
                right_stick_x,
                right_stick_y,
                left_trigger,
                right_trigger,
            )
            .await
            {
                Ok(()) => {
                    let msg = if let Some(b) = button {
                        format!("Sent gamepad button: {}", b)
                    } else {
                        "Sent gamepad analog input".into()
                    };
                    ToolResult {
                        content: vec![ContentItem {
                            content_type: "text".into(),
                            text: msg,
                        }],
                        is_error: false,
                    }
                }
                Err(e) => ToolResult {
                    content: vec![ContentItem {
                        content_type: "text".into(),
                        text: format!("Failed: {}", e),
                    }],
                    is_error: true,
                },
            }
        }

        _ => ToolResult {
            content: vec![ContentItem {
                content_type: "text".into(),
                text: format!("Unknown tool: {}", name),
            }],
            is_error: true,
        },
    };

    Ok(serde_json::to_value(result)?)
}
