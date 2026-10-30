// Canonical runtime: downloadable Node, PS1 and EXE workers embed this file.
// Jobs are text only: no repository access, shell commands, or job-selected URLs.
import { createHash, randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { chmod, mkdir, open, readFile, rename, stat, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const ENV_KEYS = new Set(["FORNAI_API_URL", "FORNAI_WORKER_TOKEN", "FORNAI_WORKER_WALLET", "FORNAI_WORKER_NAME", "FORNAI_WORKER_STATE_DIR", "FORNAI_WORKER_INTERVAL_MS", "FORNAI_LEASE_RENEW_MS", "FORNAI_REQUEST_TIMEOUT_MS", "FORNAI_INFERENCE_TIMEOUT_MS", "FREELLMAPI_BASE_URL", "FREELLMAPI_API_KEY", "FREELLMAPI_MODEL", "FREELLMAPI_MAX_TOKENS"]);
export class WorkerError extends Error {
  constructor(message, { status = 0, fatal = true } = {}) {
    super(message); this.name = "WorkerError"; this.status = status; this.fatal = fatal;
  }
}
const isLoopback = (hostname) => ["127.0.0.1", "localhost", "[::1]"].includes(hostname);
export function validateEndpoint(value, kind) {
  let url;
  try { url = new URL(value); } catch { throw new WorkerError(`Invalid ${kind} URL`); }
  if (url.username || url.password || url.search || url.hash) throw new WorkerError(`${kind} URL must not contain credentials, query parameters or fragments`);
  if (kind === "FreeLLMAPI") {
    if (!isLoopback(url.hostname) || url.protocol !== "http:" || url.pathname.replace(/\/$/, "") !== "/v1") throw new WorkerError("FreeLLMAPI must be a loopback HTTP endpoint ending in /v1");
  } else if (url.pathname !== "/" || !(url.origin === "https://fornai.dev" || (isLoopback(url.hostname) && url.protocol === "http:"))) {
    throw new WorkerError("Fornai must be https://fornai.dev or a loopback HTTP development server");
  }
  return url.href.replace(/\/$/, "");
}
function numberSetting(env, name, fallback, min = 100, max = 3_600_000) {
  const value = Number(env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new WorkerError(`Invalid ${name}`);
  return value;
}
function credential(value, name) {
  if (typeof value !== "string" || !value.trim() || /[\r\n]/.test(value)) throw new WorkerError(`${name} is required (use environment variables or .env.worker)`);
  return value.trim();
}
export function readWorkerConfig({ env = process.env, defaults = {}, cwd = process.cwd(), argv = [] } = {}) {
  const flags = { once: false, check: false, help: false };
  let envPath = env.FORNAI_WORKER_ENV_FILE || join(cwd, ".env.worker");
  let explicit = Boolean(env.FORNAI_WORKER_ENV_FILE);
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--once") flags.once = true;
    else if (arg === "--check") flags.check = true;
    else if (arg === "--help" || arg === "-h") flags.help = true;
    else if (arg === "--env-file" && argv[i + 1] && !argv[i + 1].startsWith("--")) { envPath = resolve(cwd, argv[++i]); explicit = true; }
    else throw new WorkerError("Unknown worker argument; use --help");
  }
  if (flags.help) return { flags };
  const fileEnv = {};
  if (existsSync(envPath)) {
    const content = readFileSync(envPath, "utf8");
    if (content.length > 64_000) throw new WorkerError("Worker environment file is too large");
    for (const line of content.split(/\r?\n/)) {
      const match = line.trim().match(/^([A-Z][A-Z0-9_]*)\s*=\s*(.*)$/);
      if (!match || !ENV_KEYS.has(match[1])) continue;
      let value = match[2];
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
      fileEnv[match[1]] = value;
    }
  } else if (explicit) throw new WorkerError("The requested worker environment file does not exist");
  const settings = { ...fileEnv, ...Object.fromEntries(Object.entries(env).filter(([, value]) => value !== undefined)) };
  const name = settings.FORNAI_WORKER_NAME ?? "freellmapi-relay";
  if (!/^[A-Za-z0-9._-]{1,80}$/.test(name)) throw new WorkerError("Invalid FORNAI_WORKER_NAME");
  const wallet = String(settings.FORNAI_WORKER_WALLET ?? defaults.wallet ?? "");
  if (wallet.length > 200 || /[\r\n]/.test(wallet)) throw new WorkerError("Invalid worker wallet");
  const model = settings.FREELLMAPI_MODEL ?? "auto";
  if (!model || model.length > 200 || /[\r\n]/.test(model)) throw new WorkerError("Invalid FREELLMAPI_MODEL");
  return {
    flags, name, wallet, model,
    apiUrl: validateEndpoint(settings.FORNAI_API_URL ?? defaults.apiUrl ?? "https://fornai.dev", "Fornai"),
    freeLlmUrl: validateEndpoint(settings.FREELLMAPI_BASE_URL ?? "http://127.0.0.1:31415/v1", "FreeLLMAPI"),
    workerToken: credential(settings.FORNAI_WORKER_TOKEN ?? defaults.workerToken, "FORNAI_WORKER_TOKEN"),
    freeLlmKey: credential(settings.FREELLMAPI_API_KEY, "FREELLMAPI_API_KEY"),
    stateDir: resolve(settings.FORNAI_WORKER_STATE_DIR ?? join(homedir(), ".fornai-worker", name)),
    intervalMs: numberSetting(settings, "FORNAI_WORKER_INTERVAL_MS", 15_000),
    renewMs: numberSetting(settings, "FORNAI_LEASE_RENEW_MS", 30_000),
    requestTimeoutMs: numberSetting(settings, "FORNAI_REQUEST_TIMEOUT_MS", 15_000),
    inferenceTimeoutMs: numberSetting(settings, "FORNAI_INFERENCE_TIMEOUT_MS", 180_000),
    maxTokens: numberSetting(settings, "FREELLMAPI_MAX_TOKENS", 4096, 1, 32_768),
  };
}
function redact(value, secrets) {
  let result = String(value);
  for (const secret of secrets) if (secret) result = result.split(secret).join("[REDACTED]");
  return result;
}
function pause(ms, signal) {
  if (signal?.aborted) return Promise.resolve();
  return new Promise((done) => {
    const finish = () => { clearTimeout(timer); signal?.removeEventListener("abort", finish); done(); };
    const timer = setTimeout(finish, ms);
    signal?.addEventListener("abort", finish, { once: true });
  });
}
async function readJson(path) {
  try {
    if ((await stat(path)).size > 4_000_000) throw new Error("oversize");
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw new WorkerError("Worker journal cannot be read; preserve it for recovery");
  }
}
async function writeJson(path, value) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  const file = await open(temporary, "wx", 0o600);
  try { await file.writeFile(JSON.stringify(value)); await file.sync(); } finally { await file.close(); }
  try { await rename(temporary, path); } catch (error) { await unlink(temporary).catch(() => {}); throw error; }
}
export class WorkerRuntime {
  constructor(config, { log = console.log, credentialStore = null } = {}) {
    this.config = config;
    validateEndpoint(config.apiUrl, "Fornai"); validateEndpoint(config.freeLlmUrl, "FreeLLMAPI");
    credential(config.workerToken, "FORNAI_WORKER_TOKEN"); credential(config.freeLlmKey, "FREELLMAPI_API_KEY");
    this.knownSecrets = [config.workerToken, config.freeLlmKey];
    this.log = (message) => log(redact(message, this.knownSecrets));
    this.stopController = new AbortController();
    this.pendingPath = join(config.stateDir, "pending.json"); this.lockPath = join(config.stateDir, "worker.lock");
    this.credentialPath = join(config.stateDir, "credential.json");
    // Desktop hosts can persist refreshed credentials in the OS secret store.
    // A successful write must mean durable storage before this runtime uses it.
    if (credentialStore && (typeof credentialStore.read !== "function" || typeof credentialStore.write !== "function")) throw new WorkerError("Invalid credential store");
    this.credentialStore = credentialStore;
    this.activeInference = null; this.running = false;
  }
  stop() { this.stopController.abort(); this.activeInference?.abort(); }
  tokenPayload(token) {
    try { return JSON.parse(Buffer.from(token.split(".")[0], "base64url").toString("utf8")); } catch { return null; }
  }
  async restoreCredential() {
    const saved = this.credentialStore ? await this.credentialStore.read() : await readJson(this.credentialPath);
    if (!saved || saved.apiUrl !== this.config.apiUrl || (this.config.wallet && saved.wallet !== this.config.wallet)) return;
    const current = this.tokenPayload(this.config.workerToken), candidate = this.tokenPayload(saved.token);
    if (candidate?.address !== current?.address || candidate?.address !== saved.wallet || !(Date.parse(candidate.expiresAt) > Date.parse(current?.expiresAt ?? ""))) return;
    this.config.wallet ||= saved.wallet;
    this.config.workerToken = credential(saved.token, "cached worker token"); this.knownSecrets.push(saved.token);
  }
  async refreshCredential() {
    const current = this.tokenPayload(this.config.workerToken);
    if (!current || !Number.isFinite(Date.parse(current.expiresAt)) || Date.parse(current.expiresAt) - Date.now() > 2 * 86400000) return;
    const renewed = await this.request("Fornai", "/api/worker/renew-token", { method: "POST", body: { protocolVersion: 2, wallet: this.config.wallet } });
    const candidate = this.tokenPayload(renewed.token);
    if (candidate?.address !== current.address || candidate?.scope !== "worker" || !(Date.parse(candidate.expiresAt) > Date.parse(current.expiresAt))) throw new WorkerError("Invalid renewed worker credential");
    const saved = { apiUrl: this.config.apiUrl, wallet: this.config.wallet, token: renewed.token };
    if (this.credentialStore) await this.credentialStore.write(saved);
    else await writeJson(this.credentialPath, saved);
    this.config.workerToken = credential(renewed.token, "renewed worker token"); this.knownSecrets.push(renewed.token);
    this.log("Scoped worker credential renewed.");
  }
  async request(kind, path, { method = "GET", body, signal, timeout } = {}) {
    const controller = new AbortController();
    const cancel = () => controller.abort();
    const timer = setTimeout(cancel, timeout ?? this.config.requestTimeoutMs);
    if (signal?.aborted) cancel();
    signal?.addEventListener("abort", cancel, { once: true });
    try {
      const local = kind === "FreeLLMAPI";
      const response = await fetch(`${local ? this.config.freeLlmUrl : this.config.apiUrl}${path}`, {
        method, redirect: "error", signal: controller.signal,
        headers: { "content-type": "application/json", ...(local ? { authorization: `Bearer ${this.config.freeLlmKey}` } : { "x-fornai-worker-token": this.config.workerToken }) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
      if (!response.ok) {
        await response.body?.cancel();
        throw new WorkerError(`${kind} request failed (HTTP ${response.status})`, { status: response.status, fatal: response.status < 500 && response.status !== 429 && response.status !== 408 });
      }
      const reader = response.body?.getReader();
      if (!reader) throw new WorkerError(`${kind} returned no response`);
      const chunks = []; let size = 0;
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        size += value.length;
        if (size > 2_000_000) { await reader.cancel(); throw new WorkerError(`${kind} response is too large`); }
        chunks.push(Buffer.from(value));
      }
      try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { throw new WorkerError(`${kind} returned invalid JSON`); }
    } catch (error) {
      if (error instanceof WorkerError) throw error;
      throw new WorkerError(`${kind} request interrupted or unavailable`, { fatal: false });
    } finally { clearTimeout(timer); signal?.removeEventListener("abort", cancel); }
  }
  jobs(action, body) { return this.request("Fornai", "/api/worker/jobs", { method: "POST", body: { ...body, action, protocolVersion: 2 } }); }
  heartbeat(status = "ready") {
    return this.request("Fornai", "/api/worker/heartbeat", { method: "POST", body: { name: this.config.name, wallet: this.config.wallet, tier: "builder", model: `FreeLLMAPI / ${this.config.model}`, runtime: "external-api-relay", status, protocolVersion: 2 } });
  }
  async preflight() {
    const auth = await this.request("Fornai", "/api/worker/jobs");
    if (auth.protocolVersion !== 2 || auth.authenticated !== true) throw new WorkerError("Fornai worker protocol v2 authentication is unavailable");
    if (this.config.wallet && auth.workerOwner && this.config.wallet !== auth.workerOwner) throw new WorkerError("Worker wallet does not match the token owner");
    this.config.wallet ||= auth.workerOwner || "";
    const models = await this.request("FreeLLMAPI", "/models");
    if (!Array.isArray(models.data) || models.data.length === 0) throw new WorkerError("FreeLLMAPI has no available models");
    this.log("Preflight OK: authenticated protocol v2; local FreeLLMAPI available; external API relay (no GPU or repository access).");
  }
  async acquireLock() {
    await mkdir(this.config.stateDir, { recursive: true, mode: 0o700 }); await chmod(this.config.stateDir, 0o700);
    try { this.lock = await open(this.lockPath, "wx", 0o600); } catch (error) {
      if (error.code !== "EEXIST") throw error;
      const old = await readJson(this.lockPath);
      if (!Number.isSafeInteger(old?.pid) || old.pid < 1) throw new WorkerError("Worker lock needs manual inspection");
      try { process.kill(old.pid, 0); } catch (processError) {
        if (processError.code === "ESRCH") { await unlink(this.lockPath); this.lock = await open(this.lockPath, "wx", 0o600); }
      }
      if (!this.lock) throw new WorkerError("Another worker is using this state directory");
    }
    await this.lock.writeFile(JSON.stringify({ pid: process.pid })); await this.lock.sync();
  }
  async releaseLock() {
    if (!this.lock) return;
    await this.lock.close(); this.lock = null; await unlink(this.lockPath);
  }
  validatePending(record) {
    if (record.version !== 2 || record.apiUrl !== this.config.apiUrl || record.worker !== this.config.name || record.wallet !== this.config.wallet || typeof record.id !== "string" || typeof record.leaseToken !== "string" || !["inference", "ready"].includes(record.phase)) throw new WorkerError("Pending settlement belongs to a different worker or is invalid; preserve the journal");
  }
  failedPayload(record, reason) {
    return { id: record.id, worker: this.config.name, leaseToken: record.leaseToken, status: "failed", output: reason, usage: { promptTokens: 0, completionTokens: 0 }, model: this.config.model };
  }
  async settle(record) {
    this.validatePending(record);
    if (record.phase === "inference") {
      // A crash may have followed inference: recovery must never repeat that call.
      record.phase = "ready"; record.payload = this.failedPayload(record, "Worker interrupted before a durable result was recorded; inference was not repeated.");
      await writeJson(this.pendingPath, record);
    }
    const result = await this.jobs("complete", record.payload);
    if (!result.receipt || result.receipt.jobId !== record.id || result.receipt.status !== record.payload.status) throw new WorkerError("Fornai did not return a matching settlement receipt", { fatal: false });
    const receiptDir = join(this.config.stateDir, "receipts"); await mkdir(receiptDir, { recursive: true, mode: 0o700 });
    const receiptName = createHash("sha256").update(record.id).digest("hex") + ".json";
    await writeJson(join(receiptDir, receiptName), { version: 2, jobId: record.id, apiUrl: record.apiUrl, worker: record.worker, receipt: result.receipt, duplicate: result.duplicate === true, recordedAt: new Date().toISOString() });
    await unlink(this.pendingPath);
    this.log(`Settlement acknowledged: ${record.payload.status}. Receipt saved locally.`);
    return result.receipt;
  }
  async infer(job, signal) {
    const response = await this.request("FreeLLMAPI", "/chat/completions", {
      method: "POST", signal, timeout: this.config.inferenceTimeoutMs,
      body: { model: this.config.model, stream: false, max_tokens: this.config.maxTokens, messages: [
        { role: "system", content: "You are an external API relay answering a coding task. You have no repository, filesystem, shell, or tool access. Use only the supplied text. Return useful analysis or proposed code as text; do not claim to have read files, applied patches, run commands, built, tested, or verified anything. Repository names are labels, not accessible content." },
        { role: "user", content: job.prompt },
      ] },
    });
    const output = response.choices?.[0]?.message?.content; const usage = response.usage;
    if (typeof output !== "string" || !output.trim() || output.length > 200_000) throw new WorkerError("FreeLLMAPI returned empty or oversized output");
    if (!Number.isSafeInteger(usage?.prompt_tokens) || usage.prompt_tokens < 0 || !Number.isSafeInteger(usage?.completion_tokens) || usage.completion_tokens < 0) throw new WorkerError("FreeLLMAPI did not report valid token usage");
    const model = typeof response.model === "string" && response.model.length <= 200 ? response.model : this.config.model;
    const secrets = [this.config.workerToken, this.config.freeLlmKey];
    return { output: redact(output, secrets), usage: { promptTokens: usage.prompt_tokens, completionTokens: usage.completion_tokens }, model: redact(model, secrets) };
  }
  async runJob(claim) {
    const { job, leaseToken, leaseExpiresAt } = claim;
    if (typeof job?.id !== "string" || !job.id || job.id.length > 200 || typeof leaseToken !== "string" || !leaseToken || !Number.isFinite(Date.parse(leaseExpiresAt))) throw new WorkerError("Fornai returned an invalid job lease");
    const record = { version: 2, apiUrl: this.config.apiUrl, worker: this.config.name, wallet: this.config.wallet, id: job.id, leaseToken, leaseExpiresAt, phase: "inference" };
    await writeJson(this.pendingPath, record);
    const inference = new AbortController(); this.activeInference = inference;
    const renewal = new AbortController(); let renewalError;
    const renewTask = (async () => {
      while (!renewal.signal.aborted) {
        const remaining = Date.parse(record.leaseExpiresAt) - Date.now();
        if (remaining <= 0) throw new WorkerError("Job lease expired");
        await pause(Math.min(this.config.renewMs, Math.max(100, Math.floor(remaining / 3))), renewal.signal);
        if (renewal.signal.aborted) break;
        const data = await this.jobs("renew", { id: job.id, worker: this.config.name, leaseToken });
        if (!Number.isFinite(Date.parse(data.leaseExpiresAt))) throw new WorkerError("Fornai returned an invalid renewal");
        record.leaseExpiresAt = data.leaseExpiresAt;
        await this.heartbeat("running");
      }
    })().catch((error) => { renewalError = error; inference.abort(); });
    try {
      if (this.stopController.signal.aborted) throw new WorkerError("Worker stopped before inference");
      if (typeof job.prompt !== "string" || !job.prompt.trim() || job.prompt.length > 24_000) throw new WorkerError("Job prompt is missing or too large");
      const result = await this.infer(job, inference.signal);
      if (renewalError) throw renewalError;
      record.payload = { id: job.id, worker: this.config.name, leaseToken, status: "completed", ...result };
    } catch (error) {
      const reason = this.stopController.signal.aborted ? "Worker stopped during inference." : error instanceof WorkerError ? error.message : "Inference failed.";
      record.payload = this.failedPayload(record, redact(reason, [this.config.workerToken, this.config.freeLlmKey, leaseToken]));
    } finally { renewal.abort(); await renewTask; this.activeInference = null; }
    if (renewalError && record.payload.status === "completed") record.payload = this.failedPayload(record, "Job lease could not be renewed.");
    record.phase = "ready"; await writeJson(this.pendingPath, record);
    return this.settle(record);
  }
  async cycle() {
    await this.refreshCredential();
    const pending = await readJson(this.pendingPath);
    if (pending) return this.settle(pending);
    if (this.stopController.signal.aborted) return;
    await this.heartbeat();
    if (this.stopController.signal.aborted) return;
    const claim = await this.jobs("claim", { worker: this.config.name, wallet: this.config.wallet });
    if (claim.job === null) return;
    return this.runJob(claim);
  }
  async run({ once = false, check = false } = {}) {
    if (this.running) throw new WorkerError("This worker is already running");
    this.running = true;
    try {
      await this.restoreCredential(); await this.preflight(); if (check) return;
      await this.acquireLock();
      do {
        try { await this.cycle(); } catch (error) {
          if (once || !(error instanceof WorkerError) || error.fatal) throw error;
          this.log(`${error.message}; retrying the durable settlement before claiming another job.`);
        }
        if (once || this.stopController.signal.aborted) break;
        await pause(this.config.intervalMs, this.stopController.signal);
      } while (!this.stopController.signal.aborted);
    } finally { await this.releaseLock(); this.running = false; }
  }
}
export async function runWorkerCli(defaults = {}) {
  let runtime;
  const stop = () => runtime?.stop();
  try {
    const config = readWorkerConfig({ defaults, argv: process.argv.slice(2) });
    if (config.flags.help) {
      console.log("FORNAI external API relay: node fornai-worker.mjs [--check] [--once] [--env-file PATH]\nRequires FORNAI_WORKER_TOKEN and FREELLMAPI_API_KEY. Reads .env.worker only by default. FreeLLMAPI stays on loopback; jobs cannot execute commands or access repositories. --check performs authenticated health checks without claiming jobs."); return;
    }
    runtime = new WorkerRuntime(config); process.on("SIGINT", stop); process.on("SIGTERM", stop);
    await runtime.run(config.flags);
  } catch (error) {
    console.error(error instanceof WorkerError ? error.message : "Worker stopped unexpectedly; preserve the local journal for recovery."); process.exitCode = 1;
  } finally { process.off("SIGINT", stop); process.off("SIGTERM", stop); }
}
