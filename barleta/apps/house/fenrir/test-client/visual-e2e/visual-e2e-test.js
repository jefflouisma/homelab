#!/usr/bin/env node
/**
 * Visual E2E Test for Fenrir Game Streaming
 * 
 * This test uses Moonlight CLI to:
 * 1. List available apps
 * 2. Stream RetroArch 
 * 3. Capture screenshot of the stream
 * 4. Use OpenRouter/Gemini to visually validate RetroArch UI is working
 * 
 * Requirements:
 * - Moonlight installed at /Applications/Moonlight.app
 * - OPENROUTER_API_KEY or Openrouter_API_key in .env
 * - Already paired with Fenrir (or will attempt to pair)
 */

import { spawn, execSync, exec } from 'child_process';
import { readFileSync, existsSync, mkdirSync, unlinkSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { OpenRouter } from '@openrouter/sdk';

// Load .env from homelab root
dotenv.config({ path: '/Volumes/4TB_Drive/Documents/homelab/.env' });

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Configuration
const CONFIG = {
    fenrirHost: process.env.FENRIR_HOST || '192.168.1.223',
    moonlightCli: '/Applications/Moonlight.app/Contents/MacOS/Moonlight',
    screenshotDir: join(__dirname, 'screenshots'),
    openRouterModel: 'google/gemini-2.5-pro-preview-06-05',
    streamDuration: 15000, // How long to stream before capturing screenshot (ms)
    timeout: 60000,
};

// Colors for terminal output
const Colors = {
    green: '\x1b[32m',
    red: '\x1b[31m',
    yellow: '\x1b[33m',
    blue: '\x1b[34m',
    reset: '\x1b[0m',
    bold: '\x1b[1m',
};

function log(msg, color = '') {
    const timestamp = new Date().toISOString().split('T')[1].split('.')[0];
    console.log(`${color}[${timestamp}] ${msg}${Colors.reset}`);
}

function logPass(msg) { log(`✅ PASS: ${msg}`, Colors.green); }
function logFail(msg) { log(`❌ FAIL: ${msg}`, Colors.red); }
function logInfo(msg) { log(`ℹ️  INFO: ${msg}`, Colors.blue); }
function logWarn(msg) { log(`⚠️  WARN: ${msg}`, Colors.yellow); }

/**
 * Run Moonlight CLI command and return output
 */
function runMoonlightCmd(args, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
        const fullCmd = `"${CONFIG.moonlightCli}" ${args.join(' ')}`;
        logInfo(`Running: ${fullCmd}`);

        exec(fullCmd, { timeout: timeoutMs }, (error, stdout, stderr) => {
            if (error && !error.killed) {
                reject(new Error(`Moonlight command failed: ${error.message}\nStderr: ${stderr}`));
            } else {
                resolve(stdout.trim());
            }
        });
    });
}

/**
 * List apps available on the host
 */
async function listApps() {
    try {
        const output = await runMoonlightCmd(['list', CONFIG.fenrirHost, '--verbose']);
        logInfo(`Apps list output:\n${output}`);

        // Parse output - each app name is on its own line after "Loading app list..."
        const lines = output.split('\n').filter(l => l.trim());

        // Find the index of "Loading app list..." and take everything after
        const appListIdx = lines.findIndex(l => l.includes('Loading app list'));

        let apps = [];
        if (appListIdx >= 0) {
            // Apps are listed after "Loading app list..."
            apps = lines.slice(appListIdx + 1).map(name => ({ name: name.trim() }));
        } else {
            // Fallback: assume all lines that don't look like status messages are app names
            apps = lines
                .filter(l => !l.includes('Redirecting') && !l.includes('Establishing') && !l.includes('Loading'))
                .map(name => ({ name: name.trim() }));
        }

        return apps.filter(a => a.name.length > 0);
    } catch (error) {
        logFail(`Failed to list apps: ${error.message}`);
        return [];
    }
}

/**
 * Start streaming an app (runs in background)
 */
function startStream(appName) {
    logInfo(`Starting stream of "${appName}" on ${CONFIG.fenrirHost}...`);

    const child = spawn(CONFIG.moonlightCli, [
        'stream',
        CONFIG.fenrirHost,
        appName,
        '--display-mode', 'windowed',
        '--720',
        '--fps', '30',
        '--no-vsync',
        '--no-audio-on-host',
    ], {
        detached: false,
        stdio: ['ignore', 'pipe', 'pipe']
    });

    child.stdout.on('data', (data) => {
        logInfo(`Moonlight stdout: ${data.toString().trim()}`);
    });

    child.stderr.on('data', (data) => {
        logWarn(`Moonlight stderr: ${data.toString().trim()}`);
    });

    child.on('error', (error) => {
        logFail(`Stream process error: ${error.message}`);
    });

    return child;
}

/**
 * Capture a screenshot of the screen
 */
async function captureScreenshot(filename) {
    const filepath = join(CONFIG.screenshotDir, filename);

    if (!existsSync(CONFIG.screenshotDir)) {
        mkdirSync(CONFIG.screenshotDir, { recursive: true });
    }

    try {
        execSync(`screencapture -x "${filepath}"`, { timeout: 10000 });
        logInfo(`Screenshot saved to ${filepath}`);
        return filepath;
    } catch (error) {
        logFail(`Failed to capture screenshot: ${error.message}`);
        return null;
    }
}

/**
 * Use OpenRouter API with Gemini to validate the screenshot (direct HTTP call)
 */
async function validateWithGemini(screenshotPath) {
    const apiKey = process.env.OPENROUTER_API_KEY || process.env.Openrouter_API_key;

    if (!apiKey) {
        logFail('OpenRouter API key not set');
        return { passed: false, reason: 'Missing API key' };
    }

    if (!screenshotPath || !existsSync(screenshotPath)) {
        logFail('Screenshot file does not exist');
        return { passed: false, reason: 'Screenshot not found' };
    }

    logInfo('Analyzing screenshot with Gemini vision model...');

    // Read the screenshot and convert to base64
    const imageBuffer = readFileSync(screenshotPath);
    const base64Image = imageBuffer.toString('base64');

    try {
        // Use direct HTTP API call to avoid SDK validation issues
        const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${apiKey}`,
                'HTTP-Referer': 'https://github.com/jefflouisma/homelab',
                'X-Title': 'Fenrir E2E Test'
            },
            body: JSON.stringify({
                model: CONFIG.openRouterModel,
                messages: [
                    {
                        role: 'user',
                        content: [
                            {
                                type: 'text',
                                text: `You are a QA engineer validating a game streaming test. Analyze this screenshot and determine:

1. Is there a Moonlight streaming window visible?
2. Is RetroArch UI visible? (Look for RetroArch menus, game loading screens, or emulator interface)
3. Are there any error dialogs or connection problems visible?
4. Is there actual game/emulator content being streamed?

Respond ONLY with this exact JSON format, no other text:
{
  "moonlight_window_visible": true/false,
  "retroarch_visible": true/false,
  "streaming_active": true/false,
  "error_messages": "any error text or null",
  "overall_pass": true/false,
  "description": "brief description of what you see"
}`
                            },
                            {
                                type: 'image_url',
                                image_url: {
                                    url: `data:image/png;base64,${base64Image}`
                                }
                            }
                        ]
                    }
                ],
                max_tokens: 1000,
            })
        });

        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(`HTTP ${response.status}: ${errorText}`);
        }

        const data = await response.json();
        let content = data.choices?.[0]?.message?.content || '';

        // Remove markdown code block wrappers if present
        content = content.replace(/^```json\s*/i, '').replace(/```\s*$/i, '').trim();

        logInfo(`Gemini response: ${content}`);


        // Try to parse JSON from response
        try {
            const jsonMatch = content.match(/\{[\s\S]*\}/);
            if (jsonMatch) {
                const result = JSON.parse(jsonMatch[0]);
                return {
                    passed: result.overall_pass === true,
                    moonlightVisible: result.moonlight_window_visible,
                    streamingActive: result.streaming_active,
                    retroarchVisible: result.retroarch_visible,
                    errors: result.error_messages,
                    description: result.description,
                    raw: content
                };
            }
        } catch (parseError) {
            logWarn(`Could not parse JSON from response: ${parseError.message}`);
        }

        // Fallback check
        const passed = content.toLowerCase().includes('retroarch') &&
            content.toLowerCase().includes('visible');

        return {
            passed,
            description: content,
            raw: content
        };

    } catch (error) {
        logFail(`Gemini API error: ${error.message}`);
        return { passed: false, reason: error.message };
    }
}


/**
 * Main test runner
 */
async function runTest() {
    console.log('\n' + '='.repeat(60));
    console.log(`${Colors.bold}  FENRIR VISUAL E2E TEST (Moonlight CLI)${Colors.reset}`);
    console.log('='.repeat(60) + '\n');

    logInfo(`Target: ${CONFIG.fenrirHost}`);
    logInfo(`Moonlight CLI: ${CONFIG.moonlightCli}`);
    logInfo(`AI Model: ${CONFIG.openRouterModel}`);
    console.log('');

    const results = {
        moonlightFound: false,
        apiKeyFound: false,
        appsListed: false,
        retroarchFound: false,
        streamStarted: false,
        screenshotCaptured: false,
        aiValidationPassed: false,
        retroarchVisible: false,
    };

    let streamProcess = null;

    try {
        // Step 1: Check prerequisites
        if (!existsSync(CONFIG.moonlightCli)) {
            logFail(`Moonlight not found at ${CONFIG.moonlightCli}`);
            return false;
        }
        results.moonlightFound = true;
        logPass('Moonlight CLI found');

        const apiKey = process.env.OPENROUTER_API_KEY || process.env.Openrouter_API_key;
        if (!apiKey) {
            logFail('OpenRouter API key not set');
            return false;
        }
        results.apiKeyFound = true;
        logPass('OpenRouter API key configured');

        // Step 2: List apps
        logInfo('Fetching available apps from Fenrir...');
        const apps = await listApps();

        if (apps.length > 0) {
            results.appsListed = true;
            logPass(`Found ${apps.length} apps: ${apps.map(a => a.name).join(', ')}`);
        } else {
            logFail('No apps found or failed to connect');
            return false;
        }

        // Step 3: Check for RetroArch
        const retroarchApp = apps.find(a =>
            a.name.toLowerCase().includes('retroarch') ||
            a.name.toLowerCase().includes('retro')
        );

        if (retroarchApp) {
            results.retroarchFound = true;
            logPass(`RetroArch found: "${retroarchApp.name}"`);
        } else {
            logFail('RetroArch not found in app list');
            logInfo(`Available apps: ${apps.map(a => a.name).join(', ')}`);
            return false;
        }

        // Step 4: Start streaming RetroArch
        streamProcess = startStream(retroarchApp.name);
        results.streamStarted = true;
        logPass('Stream process started');

        // Wait for stream to establish
        logInfo(`Waiting ${CONFIG.streamDuration / 1000}s for stream to stabilize...`);
        await new Promise(resolve => setTimeout(resolve, CONFIG.streamDuration));

        // Step 5: Capture screenshot
        const screenshotPath = await captureScreenshot('retroarch_stream.png');
        if (screenshotPath) {
            results.screenshotCaptured = true;
            logPass(`Screenshot captured: ${screenshotPath}`);
        } else {
            logFail('Failed to capture screenshot');
            return false;
        }

        // Step 6: Validate with Gemini
        const validation = await validateWithGemini(screenshotPath);

        if (validation.passed) {
            results.aiValidationPassed = true;
            results.retroarchVisible = validation.retroarchVisible;
            logPass('AI validation passed');
            logInfo(`Description: ${validation.description}`);
        } else {
            logFail('AI validation failed');
            logInfo(`Reason: ${validation.reason || validation.description}`);
        }

    } catch (error) {
        logFail(`Test error: ${error.message}`);
        console.error(error);
    } finally {
        // Cleanup: stop the stream
        if (streamProcess) {
            logInfo('Stopping stream...');
            streamProcess.kill('SIGTERM');
            await new Promise(r => setTimeout(r, 2000));

            // Also quit via Moonlight CLI
            try {
                await runMoonlightCmd(['quit', CONFIG.fenrirHost], 10000);
                logInfo('Stream stopped');
            } catch (e) {
                // Ignore quit errors
            }
        }
    }

    // Print summary
    console.log('\n' + '='.repeat(60));
    console.log(`${Colors.bold}  TEST RESULTS${Colors.reset}`);
    console.log('='.repeat(60));
    console.log(`  Moonlight Found:       ${results.moonlightFound ? '✅' : '❌'}`);
    console.log(`  API Key Found:         ${results.apiKeyFound ? '✅' : '❌'}`);
    console.log(`  Apps Listed:           ${results.appsListed ? '✅' : '❌'}`);
    console.log(`  RetroArch in List:     ${results.retroarchFound ? '✅' : '❌'}`);
    console.log(`  Stream Started:        ${results.streamStarted ? '✅' : '❌'}`);
    console.log(`  Screenshot Captured:   ${results.screenshotCaptured ? '✅' : '❌'}`);
    console.log(`  AI Validation Passed:  ${results.aiValidationPassed ? '✅' : '❌'}`);
    console.log(`  RetroArch Visible:     ${results.retroarchVisible ? '✅' : '❌'}`);
    console.log('='.repeat(60) + '\n');

    const overallPass = results.moonlightFound &&
        results.apiKeyFound &&
        results.appsListed &&
        results.retroarchFound &&
        results.streamStarted &&
        results.screenshotCaptured &&
        results.aiValidationPassed &&
        results.retroarchVisible;

    if (overallPass) {
        console.log(`${Colors.green}${Colors.bold}✅ ALL TESTS PASSED - RetroArch UI confirmed!${Colors.reset}\n`);
    } else {
        console.log(`${Colors.red}${Colors.bold}❌ TESTS FAILED - See above for details${Colors.reset}\n`);
    }

    return overallPass;
}

// Run the test
runTest()
    .then(passed => process.exit(passed ? 0 : 1))
    .catch(error => {
        console.error('Fatal error:', error);
        process.exit(1);
    });
