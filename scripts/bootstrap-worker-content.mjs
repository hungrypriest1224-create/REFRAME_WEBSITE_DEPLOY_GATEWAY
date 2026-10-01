import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
const token = process.env.CLOUDFLARE_API_TOKEN;
const sourceRoot = process.env.SNAPSHOT_DIR;

if (!accountId || !token || !sourceRoot) {
  throw new Error("Cloudflare credentials or SNAPSHOT_DIR are not configured.");
}

const config = JSON.parse(await readFile(resolve(sourceRoot, "wrangler.jsonc"), "utf8"));
const workerName = String(config.name || "").trim();
if (!workerName) throw new Error("Worker name is missing from wrangler.jsonc.");

const workerCode = await readFile(resolve(sourceRoot, "dist", "cloudflare", "worker.mjs"));
const form = new FormData();
form.append("metadata", JSON.stringify({ main_module: "worker.mjs" }));
form.append(
  "worker.mjs",
  new Blob([workerCode], { type: "application/javascript+module" }),
  "worker.mjs",
);

const response = await fetch(
  `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(accountId)}/workers/scripts/${encodeURIComponent(workerName)}/content`,
  {
    method: "PUT",
    headers: { Authorization: `Bearer ${token}` },
    body: form,
    signal: AbortSignal.timeout(30000),
  },
);

let payload = {};
try {
  payload = await response.json();
} catch {}

if (!response.ok || payload?.success === false) {
  const codes = Array.isArray(payload?.errors)
    ? payload.errors.map((error) => error?.code).filter((code) => code !== undefined)
    : [];
  console.error(`Direct Worker content bootstrap failed: HTTP ${response.status}${codes.length ? `, codes ${codes.join(",")}` : ""}.`);
  process.exit(1);
}

console.log("Direct Worker content bootstrap succeeded without changing bindings, routes, domains, assets, or secrets.");
