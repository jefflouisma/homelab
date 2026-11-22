const form = document.querySelector("form");
const input = document.querySelector("#pin");
const submit = form.querySelector("button");
const status = document.querySelector("#pin-status");
const retry = document.querySelector("#retry");
let request;
let ready = false;

function setReady(enabled) {
    ready = enabled;
    input.disabled = !enabled;
    submit.disabled = !enabled;
}

function showStatus(message, error = false) {
    status.textContent = message;
    status.classList.toggle("error", error);
}

function expired() {
    showStatus("This request has expired. Start pairing again in Moonlight and open the new request.", true);
}

async function checkRequest() {
    request?.abort();
    const controller = new AbortController();
    request = controller;
    setReady(false);
    retry.hidden = true;
    showStatus("Checking pairing request…");
    const secret = location.hash.slice(1);
    if (!secret) {
        expired();
        return;
    }
    try {
        const response = await fetch("/pairing/pending", {
            cache: "no-store",
            signal: AbortSignal.any([controller.signal, AbortSignal.timeout(7000)]),
        });
        if (!response.ok) throw new Error("Pairing service unavailable");
        const {secrets} = await response.json();
        if (controller.signal.aborted) return;
        if (!secrets.includes(decodeURIComponent(secret))) {
            expired();
            return;
        }
        setReady(true);
        showStatus("Ready for the PIN.");
    } catch {
        if (controller.signal.aborted) return;
        showStatus("Couldn’t check this request. Check your LAN connection and retry.", true);
        retry.hidden = false;
    }
}

form.addEventListener("submit", async event => {
    event.preventDefault();
    if (!ready || !form.reportValidity()) return;
    const pin = input.value;
    const secret = decodeURIComponent(location.hash.slice(1));
    const controller = new AbortController();
    request = controller;
    setReady(false);
    showStatus("Sending PIN…");

    try {
        const response = await fetch("/pin/", {
            method: "POST",
            headers: {"Content-Type": "application/json"},
            body: JSON.stringify({pin, secret}),
            signal: AbortSignal.any([controller.signal, AbortSignal.timeout(7000)]),
        });
        if (controller.signal.aborted) return;
        if (response.status === 410 || response.status === 409) {
            expired();
            return;
        }
        if (!response.ok) throw new Error("PIN submission failed");
        input.value = "";
        showStatus("PIN sent. Finish pairing in Moonlight.");
    } catch {
        if (controller.signal.aborted) return;
        setReady(true);
        showStatus("Couldn’t confirm the PIN was sent. If Moonlight still shows the PIN, try again.", true);
    }
});

input.addEventListener("input", () => { input.value = input.value.replace(/[^0-9]/g, ""); });
retry.addEventListener("click", checkRequest);
window.addEventListener("hashchange", () => {
    input.value = "";
    void checkRequest();
});
void checkRequest();
