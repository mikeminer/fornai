// Copyright (c) 2026 mikeminer. All rights reserved.
// SPDX-License-Identifier: LicenseRef-Fornai-Proprietary

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHostCredentialStore } from "../scripts/tray-worker.mjs";
import { WorkerRuntime } from "../scripts/worker-runtime.mjs";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const token = days => Buffer.from(JSON.stringify({ address: "owner", scope: "worker", expiresAt: new Date(Date.now() + days * 86400000).toISOString() })).toString("base64url") + ".server-signature";
test("desktop renewal waits for encrypted host storage and does not write plaintext credential.json", async () => {
  const stateDir = await mkdtemp(join(tmpdir(), "fornai-tray-test-"));
  try {
    const messages = [], store = createHostCredentialStore(message => messages.push(message));
    const current = token(1), renewed = token(7);
    const runtime = new WorkerRuntime({ stateDir, wallet: "owner", workerToken: current, freeLlmKey: "local-secret", apiUrl: "https://fornai.dev", freeLlmUrl: "http://127.0.0.1:31415/v1" }, { log: () => {}, credentialStore: store });
    runtime.request = async () => ({ token: renewed });
    const refreshing = runtime.refreshCredential();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(messages.length, 1); assert.equal(messages[0].type, "credential");
    assert.equal(runtime.config.workerToken, current);
    assert.equal(store.acknowledge({ action: "credential-saved", id: "wrong", ok: true }), false);
    store.acknowledge({ action: "credential-saved", id: messages[0].id, ok: true });
    await refreshing;
    assert.equal(runtime.config.workerToken, renewed);
    assert.deepEqual(await readdir(stateDir), []);
    assert.equal(store.acknowledge({ action: "credential-saved", id: messages[0].id, ok: true }), false);
  } finally { await rm(stateDir, { recursive: true, force: true }); }
});
test("host write failures, timeout and host disconnect never confirm credential storage", async () => {
  const messages = [], store = createHostCredentialStore(message => messages.push(message), { timeoutMs: 15 });
  const failed = store.write({ token: "secret", wallet: "owner" });
  store.acknowledge({ action: "credential-saved", id: messages[0].id, ok: false });
  await assert.rejects(failed, /protezione sicura del sistema/);
  await assert.rejects(store.write({ token: "secret", wallet: "owner" }), /non è stato confermato/);
  const disconnected = store.write({ token: "secret", wallet: "owner" });
  store.close(); await assert.rejects(disconnected, /chiusa/);
});

test("native app IPC starts the real adapter and pauses it gracefully without leaking credentials", async () => {
  const stateDir = await mkdtemp(join(tmpdir(), "fornai-tray-ipc-"));
  const events = [], violations = [];
  let processChild;
  const server = createServer(async (request, response) => {
    let raw = ""; for await (const chunk of request) raw += chunk;
    const body = raw ? JSON.parse(raw) : {};
    const local = request.url.startsWith("/v1/");
    if (local ? request.headers["x-fornai-worker-token"] : request.headers.authorization) violations.push("credentials crossed destinations");
    response.setHeader("content-type", "application/json");
    const data = local ? { data: [{ id: "test" }] }
      : request.url === "/api/worker/heartbeat" ? { ok: true, status: body.status }
      : request.method === "GET" ? { protocolVersion: 2, authenticated: true, workerOwner: "owner" } : { job: null };
    response.end(JSON.stringify(data));
  });
  try {
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const origin = `http://127.0.0.1:${server.address().port}`;
    processChild = spawn(process.execPath, [fileURLToPath(new URL("../scripts/tray-worker.mjs", import.meta.url))], {
      cwd: stateDir, windowsHide: true, stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, FORNAI_API_URL: origin, FORNAI_WORKER_TOKEN: "private-worker-token", FORNAI_WORKER_WALLET: "owner", FORNAI_WORKER_NAME: "desktop-test", FORNAI_WORKER_STATE_DIR: stateDir, FREELLMAPI_BASE_URL: origin + "/v1", FREELLMAPI_API_KEY: "private-local-key", FREELLMAPI_MODEL: "test", FORNAI_WORKER_ENV_FILE: "" },
    });
    const lines = createInterface({ input: processChild.stdout });
    lines.on("line", line => {
      const event = JSON.parse(line); events.push(event);
      if (event.type === "status" && event.state === "ready") processChild.stdin.write('{"action":"stop"}\n');
    });
    const exit = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { processChild.kill(); reject(new Error("Desktop IPC did not stop")); }, 15000);
      processChild.once("error", error => { clearTimeout(timer); reject(error); });
      processChild.once("exit", code => { clearTimeout(timer); resolve(code); });
    });
    assert.equal(exit, 0); assert.deepEqual(violations, []);
    const states = events.filter(event => event.type === "status").map(event => event.state);
    assert.equal(states[0], "starting"); assert.ok(states.includes("ready")); assert.equal(states.at(-1), "paused");
    const emitted = JSON.stringify(events);
    assert.ok(!emitted.includes("private-worker-token") && !emitted.includes("private-local-key"));
    assert.ok(!(await readdir(stateDir)).includes("worker.lock"));
  } finally {
    if (processChild && processChild.exitCode === null) processChild.kill();
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    await rm(stateDir, { recursive: true, force: true });
  }
});
