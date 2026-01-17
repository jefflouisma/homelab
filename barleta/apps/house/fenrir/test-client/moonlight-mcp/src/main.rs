//! Moonlight MCP - E2E Testing Tool for Fenrir Game Streaming
//!
//! Native implementation of GameStream protocol:
//! - JSON-based E2E test definitions
//! - MCP stdio protocol for AI agent integration
//! - Visual validation via OpenRouter/Gemini

mod mcp;
mod pairing;
mod tests;
mod validator;

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "moonlight-mcp")]
#[command(about = "MCP tool for Moonlight E2E testing with AI validation")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Run as MCP stdio server
    #[arg(long)]
    mcp: bool,

    /// Path to .env file (default: /Volumes/4TB_Drive/Documents/homelab/.env)
    #[arg(long, default_value = "/Volumes/4TB_Drive/Documents/homelab/.env")]
    env_file: String,
}

#[derive(Subcommand)]
enum Commands {
    /// Run a test from JSON file
    Test {
        /// Path to JSON test file
        #[arg(short, long)]
        file: PathBuf,
    },
    /// List apps on host
    List {
        /// Host address
        #[arg(short = 'H', long)]
        host: String,
    },
    /// Pair with host
    Pair {
        /// Host address
        #[arg(short = 'H', long)]
        host: String,
        /// PIN code
        #[arg(short, long)]
        pin: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    // Load environment variables
    let env_path = shellexpand::tilde(&cli.env_file).to_string();
    if let Err(e) = dotenvy::from_path(&env_path) {
        eprintln!("Warning: Could not load {}: {}", env_path, e);
    }

    if cli.mcp {
        // Run as MCP stdio server
        mcp::run_mcp_server().await
    } else {
        match cli.command {
            Some(Commands::Test { file }) => {
                tests::run_test_file(&file).await
            }
            Some(Commands::List { host }) => {
                let apps = pairing::native_list_apps(&host).await?;
                for app in apps {
                    println!("{} (ID: {})", app.title, app.id);
                }
                Ok(())
            }
            Some(Commands::Pair { host, pin }) => {
                println!("Pairing with {} using native protocol...", host);
                pairing::native_pair(&host, &pin).await?;
                println!("Pairing successful!");
                Ok(())
            }
            None => {
                // Default: run as MCP server
                eprintln!("No command specified. Use --help for usage or --mcp for MCP mode.");
                Ok(())
            }
        }
    }
}
