# Native controller testing on Apple Silicon

This helper connects the MCP gamepad commands to a real Moonlight Qt stream. Moonlight performs the GameStream handshake, encryption, and video decoding. A virtual SDL Xbox controller supplies input to that client.

Requirements: installed `/Applications/Moonlight.app` with its SDL2 framework, Python 3.11 or newer, and Apple Command Line Tools. The launcher copies and signs a separate test client under `/Volumes/4TB_Drive/tmp/`; it does not modify the installed application.

From the repository root:

```sh
export TMPDIR=/Volumes/4TB_Drive/tmp/
export FENRIR_NATIVE_DIR=/Volumes/4TB_Drive/tmp/fenrir-native-test
scripts/native-moonlight/run.sh pair 192.168.1.221 7482
```

Enter the same PIN at <http://192.168.1.221:47989/>. Close that test client after pairing, then start a stream:

```sh
scripts/native-moonlight/run.sh stream 192.168.1.221 EmuDeck \
  --resolution 1920x1080 --display-mode windowed
export MOONLIGHT_INPUT_COMMAND="$PWD/scripts/native-moonlight/input.py"
```

Pass `TMPDIR`, `FENRIR_NATIVE_DIR`, and `MOONLIGHT_INPUT_COMMAND` to the `moonlight-mcp` process. The command path must be an executable, without arguments. `moonlight_send_gamepad` then uses the running test client. Direct provider example:

```sh
printf '%s\n' '{"type":"gamepad","host":"192.168.1.221","button":"a","button_action":"tap"}' \
  | scripts/native-moonlight/input.py
```

The provider validates the target host, buttons, sticks, and triggers. It returns `{"acknowledged":true}` only after SDL accepts every requested change. This confirms local delivery; inspect the streamed game or capture before/after frames to verify its reaction. Keyboard and mouse requests are unsupported by this provider and return an error. Raw control-stream verification is also unsupported by the Rust tool.

Use a separate test pairing/profile when testing against an active user. Stop only this client's PID, recorded in `$FENRIR_NATIVE_DIR/client.pid`, and remove only the pairing/session created for that test. Keep logs and captures under the required temporary root. After testing, remove the owned client directory when it is no longer running.
