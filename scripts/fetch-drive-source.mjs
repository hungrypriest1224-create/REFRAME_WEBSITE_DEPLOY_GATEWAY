import { createHash, createSign } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";

const folderId = process.env.DRIVE_SOURCE_FOLDER_ID;
const serviceAccountText = process.env.GDRIVE_SERVICE_ACCOUNT_JSON;
const snapshotPathValue = process.env.SNAPSHOT_DIR;
if (!folderId || !serviceAccountText || !snapshotPathValue) {
  throw new Error("Drive source folder, service-account secret, or temporary snapshot path is not configured.");
}

const runnerTemp = process.env.RUNNER_TEMP ? resolve(process.env.RUNNER_TEMP) : "";
const snapshotRoot = resolve(snapshotPathValue);
if (!isAbsolute(snapshotPathValue) || !runnerTemp || !snapshotRoot.startsWith(`${runnerTemp}${sep}`)) {
  throw new Error("Snapshot path must be inside the GitHub runner temporary directory.");
}

const serviceAccount = JSON.parse(serviceAccountText);
if (!serviceAccount.client_email || !serviceAccount.private_key) {
  throw new Error("Drive service-account secret is incomplete.");
}

const maxFiles = 500;
const maxFileBytes = 25 * 1024 * 1024;
const maxTotalBytes = 100 * 1024 * 1024;
const manifestPath = ".reframe-source-manifest.json";
const encoder = new TextEncoder();

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function safeName(name) {
  if (!name || name === "." || name === ".." || /[<>:"/\\|?*\u0000-\u001f]/u.test(name) || /[. ]$/u.test(name)) return false;
  if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/iu.test(name)) return false;
  return true;
}

function rejectSensitivePath(path) {
  const normalized = path.replaceAll("\\", "/");
  if (/(?:^|\/)(?:\.git|dist|node_modules|\.wrangler)(?:\/|$)/iu.test(normalized)) return true;
  const basename = normalized.split("/").at(-1) ?? "";
  return /^(?:\.env(?:\..*)?|\.dev\.vars(?:\..*)?|service[-_]?account.*\.json|.*\.(?:pem|p12|pfx|key))$/iu.test(basename);
}

async function getAccessToken() {
  const issuedAt = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/drive.readonly",
    aud: "https://oauth2.googleapis.com/token",
    iat: issuedAt,
    exp: issuedAt + 3600,
  }));
  const unsigned = `${header}.${claims}`;
  const signer = createSign("RSA-SHA256");
  signer.update(unsigned);
  signer.end();
  const assertion = `${unsigned}.${signer.sign(serviceAccount.private_key).toString("base64url")}`;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
    signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) throw new Error(`Google OAuth token request failed (HTTP ${response.status}).`);
  const payload = await response.json();
  if (!payload.access_token) throw new Error("Google OAuth did not return an access token.");
  return payload.access_token;
}

const accessToken = await getAccessToken();

async function listChildren(parentId) {
  const files = [];
  let pageToken;
  do {
    const url = new URL("https://www.googleapis.com/drive/v3/files");
    url.searchParams.set("q", `'${parentId}' in parents and trashed = false`);
    url.searchParams.set("pageSize", "1000");
    url.searchParams.set("orderBy", "name");
    url.searchParams.set("fields", "nextPageToken,files(id,name,mimeType,size,modifiedTime,md5Checksum)");
    url.searchParams.set("supportsAllDrives", "true");
    url.searchParams.set("includeItemsFromAllDrives", "true");
    if (pageToken) url.searchParams.set("pageToken", pageToken);
    const response = await fetch(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
      signal: AbortSignal.timeout(30000),
    });
    if (!response.ok) throw new Error(`Google Drive listing failed (HTTP ${response.status}).`);
    const payload = await response.json();
    files.push(...(payload.files ?? []));
    pageToken = payload.nextPageToken;
  } while (pageToken);
  return files;
}

async function scanTree(rootId) {
  const records = [];
  async function visit(parentId, prefix = "", depth = 0) {
    if (depth > 20) throw new Error("Drive source has too many nested folders.");
    const children = await listChildren(parentId);
    for (const item of children) {
      if (!safeName(item.name)) throw new Error("Drive source contains a name that is unsafe on the Windows runner.");
      const relativePath = prefix ? `${prefix}/${item.name}` : item.name;
      if (rejectSensitivePath(relativePath)) throw new Error("Drive source contains a build, credential, or environment file that is not allowed.");
      if (item.mimeType === "application/vnd.google-apps.shortcut") throw new Error("Drive source shortcuts are not allowed.");
      const record = {
        id: item.id,
        path: relativePath,
        mimeType: item.mimeType,
        size: Number(item.size ?? 0),
        modifiedTime: item.modifiedTime ?? "",
        md5Checksum: item.md5Checksum ?? "",
      };
      records.push(record);
      if (item.mimeType === "application/vnd.google-apps.folder") {
        await visit(item.id, relativePath, depth + 1);
      } else if (item.mimeType.startsWith("application/vnd.google-apps.")) {
        throw new Error("Drive source must contain ordinary files, not Google Docs, shortcuts, or other virtual files.");
      }
    }
  }
  await visit(rootId);
  records.sort((a, b) => a.path.localeCompare(b.path, "en"));
  if (records.length > maxFiles) throw new Error(`Drive source exceeds the ${maxFiles}-item safety limit.`);
  const fileRecords = records.filter((record) => record.mimeType !== "application/vnd.google-apps.folder");
  if (fileRecords.length === 0) throw new Error("Drive source folder is empty.");
  const caseFoldedPaths = new Set();
  let totalBytes = 0;
  for (const record of fileRecords) {
    const folded = record.path.toLocaleLowerCase("en-US");
    if (caseFoldedPaths.has(folded)) throw new Error("Drive source contains filenames that collide on Windows.");
    caseFoldedPaths.add(folded);
    if (record.size > maxFileBytes) throw new Error("Drive source contains a file larger than the safety limit.");
    totalBytes += record.size;
  }
  if (totalBytes > maxTotalBytes) throw new Error("Drive source exceeds the temporary snapshot size limit.");
  return { records, fileRecords, totalBytes };
}

function metadataFingerprint(records) {
  const stable = records.map(({ id, path, mimeType, size, modifiedTime, md5Checksum }) =>
    [id, path, mimeType, size, modifiedTime, md5Checksum].join("\t"),
  ).join("\n");
  return sha256(encoder.encode(stable));
}

const before = await scanTree(folderId);
const expectedPaths = new Set(before.fileRecords.map((record) => record.path));
const required = [
  "AGENTS.md",
  "README.md",
  "package.json",
  "wrangler.jsonc",
  "src/worker.mjs",
  "scripts/build.mjs",
  "scripts/test-worker-auth.mjs",
  "scripts/verify-live.mjs",
  "scripts/deploy-cloudflare.ps1",
  "scripts/initialize-cloudflare-secrets.ps1",
];
for (const path of required) {
  if (!expectedPaths.has(path)) throw new Error(`Drive source is missing a required project file: ${path}`);
}

const tempRoot = resolve(runnerTemp);
const relativeToTemp = relative(tempRoot, snapshotRoot);
if (!relativeToTemp || relativeToTemp.startsWith(`..${sep}`) || relativeToTemp === "..") {
  throw new Error("Snapshot cleanup target is not a dedicated child of the runner temporary directory.");
}
await rm(snapshotRoot, { recursive: true, force: true });
await mkdir(snapshotRoot, { recursive: true });
const fileHashes = [];

for (const file of before.fileRecords) {
  const url = new URL(`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(file.id)}`);
  url.searchParams.set("alt", "media");
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
    signal: AbortSignal.timeout(60000),
  });
  if (!response.ok) throw new Error(`Drive source download failed (HTTP ${response.status}).`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.byteLength > maxFileBytes) throw new Error("Downloaded Drive file exceeds the safety limit.");
  const target = resolve(snapshotRoot, ...file.path.split("/"));
  if (!target.startsWith(`${snapshotRoot}${sep}`)) throw new Error("Drive source path escaped the temporary snapshot.");
  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, bytes);
  fileHashes.push([file.path, sha256(bytes)]);
}

const after = await scanTree(folderId);
if (metadataFingerprint(before.records) !== metadataFingerprint(after.records)) {
  await rm(snapshotRoot, { recursive: true, force: true });
  throw new Error("Drive source changed while the snapshot was being downloaded. No deployment was attempted.");
}

const snapshotHash = sha256(encoder.encode(fileHashes.sort(([a], [b]) => a.localeCompare(b, "en")).map(([path, hash]) => `${path}\t${hash}`).join("\n")));
const outputFile = process.env.GITHUB_OUTPUT;
if (outputFile) {
  const prior = await readFile(outputFile, "utf8").catch(() => "");
  await writeFile(outputFile, `${prior}source_fingerprint=${snapshotHash}\n`, "utf8");
}
console.log(`Fetched ${fileHashes.length} Drive source files (${before.totalBytes} bytes); stable snapshot ${snapshotHash}.`);

