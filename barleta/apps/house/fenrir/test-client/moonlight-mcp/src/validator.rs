//! OpenRouter visual validation module
//!
//! Sends screenshots to Gemini for AI-based visual validation

use anyhow::{anyhow, Result};
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Validation result from Gemini
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationResult {
    pub passed: bool,
    pub moonlight_visible: bool,
    pub app_visible: bool,
    pub streaming_active: bool,
    pub error_messages: Option<String>,
    pub description: String,
    pub raw_response: String,
}

impl Default for ValidationResult {
    fn default() -> Self {
        Self {
            passed: false,
            moonlight_visible: false,
            app_visible: false,
            streaming_active: false,
            error_messages: None,
            description: String::new(),
            raw_response: String::new(),
        }
    }
}

/// OpenRouter chat completion response
#[derive(Debug, Deserialize)]
struct ChatResponse {
    choices: Vec<Choice>,
}

#[derive(Debug, Deserialize)]
struct Choice {
    message: Message,
}

#[derive(Debug, Deserialize)]
struct Message {
    content: String,
}

/// Gemini's structured response
#[derive(Debug, Deserialize)]
struct GeminiAnalysis {
    moonlight_window_visible: Option<bool>,
    retroarch_visible: Option<bool>,
    app_visible: Option<bool>,
    streaming_active: Option<bool>,
    error_messages: Option<String>,
    overall_pass: Option<bool>,
    description: Option<String>,
}

/// Validate screenshot with OpenRouter/Gemini
pub async fn validate_screenshot(
    screenshot_path: &str,
    expected_app: &str,
) -> Result<ValidationResult> {
    let api_key = std::env::var("OPENROUTER_API_KEY")
        .or_else(|_| std::env::var("Openrouter_API_key"))
        .map_err(|_| anyhow!("OpenRouter API key not found in environment"))?;

    // Read and encode screenshot
    let image_data = tokio::fs::read(screenshot_path).await?;
    let base64_image = base64::engine::general_purpose::STANDARD.encode(&image_data);

    // Build the prompt
    let prompt = format!(
        r#"You are a QA engineer validating a game streaming test. Analyze this screenshot and determine:

1. Is there a Moonlight streaming window visible?
2. Is {} visible? (Look for menus, loading screens, or UI elements)
3. Are there any error dialogs or connection problems visible?
4. Is there actual content being streamed?

Respond ONLY with this exact JSON format, no other text:
{{
  "moonlight_window_visible": true/false,
  "app_visible": true/false,
  "streaming_active": true/false,
  "error_messages": "any error text or null",
  "overall_pass": true/false,
  "description": "brief description of what you see"
}}"#,
        expected_app
    );

    // Make API request
    let client = reqwest::Client::new();
    let response = client
        .post("https://openrouter.ai/api/v1/chat/completions")
        .header("Authorization", format!("Bearer {}", api_key))
        .header("Content-Type", "application/json")
        .header("HTTP-Referer", "https://github.com/jefflouisma/homelab")
        .header("X-Title", "Fenrir E2E Test")
        .json(&serde_json::json!({
            "model": "google/gemini-3-pro-image-preview",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": prompt
                        },
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": format!("data:image/png;base64,{}", base64_image)
                            }
                        }
                    ]
                }
            ],
            "max_tokens": 1000
        }))
        .send()
        .await?;

    if !response.status().is_success() {
        let error_text = response.text().await?;
        return Err(anyhow!("OpenRouter API error: {}", error_text));
    }

    let chat_response: ChatResponse = response.json().await?;
    let mut content = chat_response
        .choices
        .first()
        .map(|c| c.message.content.clone())
        .unwrap_or_default();

    // Strip markdown code block if present
    content = content
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim()
        .to_string();

    // Try to parse JSON
    let mut result = ValidationResult {
        raw_response: content.clone(),
        ..Default::default()
    };

    if let Ok(analysis) = serde_json::from_str::<GeminiAnalysis>(&content) {
        result.passed = analysis.overall_pass.unwrap_or(false);
        result.moonlight_visible = analysis.moonlight_window_visible.unwrap_or(false);
        result.app_visible =
            analysis.app_visible.unwrap_or(false) || analysis.retroarch_visible.unwrap_or(false);
        result.streaming_active = analysis.streaming_active.unwrap_or(false);
        result.error_messages = analysis.error_messages;
        result.description = analysis.description.unwrap_or_default();
    } else {
        // Fallback: check for keywords
        let lower = content.to_lowercase();
        result.passed = lower.contains("visible") && lower.contains(expected_app.to_lowercase().as_str());
        result.description = content;
    }

    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validation_result_default() {
        let result = ValidationResult::default();
        assert!(!result.passed);
    }
}
