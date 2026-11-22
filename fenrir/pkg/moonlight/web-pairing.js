const requests = document.querySelector("#requests");
const refresh = document.querySelector("#refresh");
const status = document.querySelector("#refresh-status");
let refreshing = false;

async function refreshRequests() {
    if (document.hidden || refreshing) return;
    refreshing = true;

    try {
        const response = await fetch("/pairing/pending", {
            cache: "no-store",
            signal: AbortSignal.timeout(7000),
        });
        if (!response.ok) throw new Error("Pairing requests unavailable");
        const {secrets} = await response.json();
        const links = new Map([...requests.querySelectorAll("a")].map(link => [
            decodeURIComponent(link.hash.slice(1)), link,
        ]));

        if (links.size !== secrets.length || secrets.some(secret => !links.has(secret))) {
            if (secrets.length === 0) {
                requests.replaceChildren(document.querySelector("#empty-template").content.cloneNode(true));
            } else {
                requests.querySelector(".empty")?.remove();
                for (const [secret, link] of links) {
                    if (!secrets.includes(secret)) {
                        if (document.activeElement === link) refresh.focus();
                        link.closest(".request-row").remove();
                    }
                }
                for (const secret of secrets) {
                    if (links.has(secret)) continue;
                    const row = document.querySelector("#request-template").content.cloneNode(true);
                    row.querySelector("a").href = "/pin/#" + encodeURIComponent(secret);
                    requests.append(row);
                }
            }
        }
        status.textContent = "Requests refresh automatically.";
        status.classList.remove("error");
    } catch {
        status.textContent = "Couldn’t refresh requests. Check your LAN connection and try again.";
        status.classList.add("error");
    } finally {
        refreshing = false;
    }
}

refresh.hidden = false;
refresh.addEventListener("click", refreshRequests);
document.addEventListener("visibilitychange", refreshRequests);
setInterval(refreshRequests, 5000);
void refreshRequests();
