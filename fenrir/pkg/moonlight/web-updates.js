const packages = document.querySelector("#packages");
const container = document.querySelector("#components");
const template = document.querySelector("#component-template");
const loadNotice = document.querySelector("#load-notice");
const loadStatus = document.querySelector("#load-status");
const retry = document.querySelector("#retry");
const activationStatus = document.querySelector("#activation-status");
const summary = document.querySelector("#summary");

const components = [
    ["emudeck", "EmuDeck", "ES-DE frontend"],
    ["rpcs3", "RPCS3", "PlayStation 3"],
    ["shadps4", "shadPS4", "PlayStation 4"],
    ["kytyps5", "KytyPS5", "PlayStation 5"],
    ["ps5plus", "PS5Plus", "PlayStation 5 · KytyPS5 fork"],
    ["eden", "Eden", "Nintendo Switch"],
    ["eglantine", "Eglantine", "Nintendo Switch 2 · Pre-release"],
];

const cards = new Map();
const pendingActions = new Set();
const dateFormat = new Intl.DateTimeFormat(undefined, {dateStyle: "medium", timeStyle: "short"});
let snapshot;
let refreshRequest;
let connected = false;

function addCard(id, name, platform) {
    const card = template.content.firstElementChild.cloneNode(true);
    const fields = Object.fromEntries([...card.querySelectorAll("[data-field]")].map(el => [el.dataset.field, el]));
    const buttons = Object.fromEntries([...card.querySelectorAll("[data-action]")].map(el => [el.dataset.action, el]));
    const select = card.querySelector("select");
    fields.name.textContent = name;
    fields.name.id = id + "-name";
    fields.platform.textContent = platform;
    card.setAttribute("aria-labelledby", fields.name.id);
    select.id = id + "-previous";
    card.querySelector("label").htmlFor = select.id;
    for (const [command, button] of Object.entries(buttons)) {
        button.addEventListener("click", () => void action(id, command));
    }
    container.append(card);
    cards.set(id, {card, fields, buttons, select});
}

function updateReady(state) {
    return Boolean(state.staged && state.staged.version !== state.active && !state.queued);
}

function renderCard(id, state) {
    const {card, fields, buttons, select} = cards.get(id);
    card.hidden = !state;
    if (!state) return;

    const ready = updateReady(state);
    const disabled = !connected || pendingActions.has(id);
    const checked = state.checked && !state.checked.startsWith("0001") ? new Date(state.checked) : null;
    const previous = state.previous || [];
    fields.active.textContent = state.active || "Not installed";
    fields.available.textContent = state.available?.version || "Not checked";
    fields.staged.textContent = state.staged?.version || "None";
    fields.checked.textContent = checked ? "Last checked " + dateFormat.format(checked) : "Waiting for first check";
    fields.error.textContent = state.error || "";
    fields.error.hidden = !state.error;
    fields.queue.textContent = state.queued ? "Queued version " + state.queued : "";
    fields.queue.hidden = !state.queued;

    const [tone, label] = state.queued ? ["queued", "Queued"] :
        state.busy ? ["", "Checking"] :
        ready ? ["ready", "Update ready"] :
        state.error ? ["", "Check failed"] :
        state.active && state.available?.version === state.active ? ["", "Up to date"] :
        state.available ? ["", "Awaiting package"] : ["", "Not checked"];
    fields.state.dataset.state = tone;
    fields.state.textContent = label;

    const selected = select.value;
    if (previous.length !== select.options.length || previous.some((version, index) => select.options[index].value !== version)) {
        select.replaceChildren(...previous.map(version => new Option(version, version)));
        if (previous.includes(selected)) select.value = selected;
    }
    fields.rollback.hidden = previous.length === 0;
    fields["no-previous"].hidden = previous.length > 0;
    select.disabled = disabled || Boolean(state.queued);
    buttons.check.disabled = disabled || state.busy;
    buttons.apply.hidden = !ready;
    buttons.apply.disabled = disabled || state.busy;
    buttons.cancel.hidden = !state.queued;
    buttons.cancel.disabled = disabled;
    buttons.rollback.disabled = disabled || Boolean(state.queued) || previous.length === 0;
}

function render() {
    if (!snapshot) return;
    const states = components.map(([id]) => snapshot.components[id]).filter(Boolean);
    const updates = states.filter(updateReady).length;
    const queued = states.filter(state => state.queued).length;
    summary.textContent = states.length ? `${states.length} packages · ${updates} ready · ${queued} queued` : "No packages available";
    activationStatus.hidden = !snapshot.activation_error;
    activationStatus.textContent = snapshot.activation_error ? "Activation paused. " + snapshot.activation_error : "";
    for (const [id] of components) renderCard(id, snapshot.components[id]);
    packages.hidden = false;
}

async function refresh() {
    if (document.hidden || refreshRequest || pendingActions.size) return;
    const controller = new AbortController();
    refreshRequest = controller;
    try {
        const response = await fetch("/api/updates", {
            cache: "no-store",
            signal: AbortSignal.any([controller.signal, AbortSignal.timeout(8000)]),
        });
        if (!response.ok) throw new Error("Update service unavailable");
        const data = await response.json();
        if (controller.signal.aborted) return;
        snapshot = data;
        connected = true;
        const restoreFocus = document.activeElement === retry;
        render();
        if (restoreFocus) document.querySelector("#packages-heading").focus();
        loadNotice.hidden = true;
        retry.hidden = true;
    } catch {
        if (controller.signal.aborted) return;
        connected = false;
        loadNotice.hidden = false;
        retry.hidden = false;
        loadStatus.textContent = snapshot ?
            "Couldn’t refresh. Previous results are shown until Fenrir reconnects." :
            "Couldn’t load emulator versions. Check your LAN connection and retry.";
        render();
    } finally {
        if (refreshRequest === controller) refreshRequest = undefined;
    }
}

const outcomes = {
    check: "Checking for releases and staging the latest verified package.",
    apply: "Update queued. It will apply after active sessions end.",
    cancel: "Queued change cancelled.",
    rollback: "Rollback queued. It will apply after active sessions end.",
};

async function action(id, command) {
    if (!connected || pendingActions.has(id)) return;
    const {fields, select} = cards.get(id);
    pendingActions.add(id);
    refreshRequest?.abort();
    refreshRequest = undefined;
    render();
    fields.result.textContent = "Sending request…";
    fields.result.classList.remove("error");
    try {
        const response = await fetch(`/api/updates/${id}/${command}`, {
            method: "POST",
            headers: {"Content-Type": "application/json"},
            body: JSON.stringify(command === "rollback" ? {version: select.value} : {}),
            signal: AbortSignal.timeout(10000),
        });
        if (!response.ok) throw new Error((await response.text()).trim() || "The update service rejected the request.");
        fields.result.textContent = outcomes[command];
    } catch (error) {
        fields.result.classList.add("error");
        fields.result.textContent = error.name === "TimeoutError" ?
            "Couldn’t confirm the request. Check the current package status before retrying." :
            "Couldn’t complete the request. " + error.message;
    } finally {
        pendingActions.delete(id);
        if (pendingActions.size) render();
        else await refresh();
    }
}

for (const component of components) addCard(...component);
retry.addEventListener("click", refresh);
document.addEventListener("visibilitychange", refresh);
setInterval(refresh, 5000);
void refresh();
