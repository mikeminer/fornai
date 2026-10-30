// Copyright (c) 2026 mikeminer. All rights reserved.
// SPDX-License-Identifier: LicenseRef-Fornai-Proprietary

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import test from "node:test";
import { WorkerRuntime, readWorkerConfig, validateEndpoint } from "../scripts/worker-runtime.mjs";

const wallet = "DummySolanaWalletCaseSensitive";
const token = "test-worker-token-not-a-secret";
const key = "test-local-freellmapi-key";
const reply = { model: "served-free-model", choices: [{ message: { content: "Here is the actual proposed function." } }], usage: { prompt_tokens: 19, completion_tokens: 8 } };

async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), "fornai-worker-test-"));
  const events = { claims: 0, inference: 0, renewals: 0, completions: [], remoteHeaders: [], localHeaders: [], prompts: [], active: 0, maxActive: 0 };
  const json = (res, status, value) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(value)); };
  const server = createServer(async (req, res) => {
    try {
      let raw = ""; for await (const chunk of req) raw += chunk;
      const body = raw ? JSON.parse(raw) : null;
      if (req.url.startsWith("/v1/")) events.localHeaders.push(req.headers);
      else events.remoteHeaders.push(req.headers);
      if (req.url === "/v1/models") return json(res, options.localAuthFailure ? 401 : 200, { data: [{ id: "auto" }] });
      if (req.url === "/v1/chat/completions") {
        events.inference++; events.active++; events.maxActive = Math.max(events.maxActive, events.active); events.prompts.push(body);
        options.onInference?.();
        await delay(options.inferenceDelay ?? 0);
        events.active--;
        if (options.inferenceFailure) return json(res, 500, { error: { message: `do not forward ${key}` } });
        return json(res, 200, options.reply ?? reply);
      }
      if (req.url === "/api/worker/heartbeat") return json(res, 200, { presenceOnly: true });
      if (req.url !== "/api/worker/jobs") return json(res, 404, {});
      if (req.method === "GET") {
        if (options.authRedirect) { res.writeHead(302, { location: "/capture-secret" }); res.end(); return; }
        return json(res, options.authFailure ? 401 : 200, { protocolVersion: 2, authenticated: true, workerOwner: wallet, leaseDurationMs: 120000 });
      }
      assert.equal(body.protocolVersion, 2);
      assert.equal(req.headers["x-fornai-worker-token"], token);
      if (body.action === "claim") {
        events.claims++;
        return json(res, 200, events.claims > (options.jobs ?? 1) ? { job: null } : {
          job: { id: `job-${events.claims}`, prompt: "Propose a function. Do not run any commands.", repo: "private/repo-label", command: "must never execute", apiUrl: "https://untrusted.invalid" },
          leaseToken: `lease-${events.claims}`, leaseExpiresAt: new Date(Date.now() + 120000).toISOString(),
        });
      }
      if (body.action === "renew") { events.renewals++; return json(res, 200, { leaseExpiresAt: new Date(Date.now() + 120000).toISOString() }); }
      if (body.action === "complete") {
        events.completions.push(body);
        if (options.completionFailures && events.completions.length <= options.completionFailures) return json(res, 503, {});
        json(res, 200, { receipt: { jobId: body.id, status: body.status, rewardBaseUnits: body.status === "completed" ? "8" : "0", refundBaseUnits: "0", settledAt: new Date().toISOString() }, duplicate: events.completions.length > 1 && events.completions.at(-2).id === body.id });
        options.onComplete?.(body);
        return;
      }
      return json(res, 400, {});
    } catch (error) { json(res, 500, { error: String(error) }); }
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const env = {
    FORNAI_API_URL: origin, FORNAI_WORKER_TOKEN: token, FORNAI_WORKER_WALLET: wallet,
    FORNAI_WORKER_STATE_DIR: join(root, "state"), FORNAI_WORKER_NAME: "test-relay",
    FORNAI_WORKER_INTERVAL_MS: "100", FORNAI_LEASE_RENEW_MS: "100", FORNAI_REQUEST_TIMEOUT_MS: "2000",
    FORNAI_INFERENCE_TIMEOUT_MS: "5000", FREELLMAPI_BASE_URL: `${origin}/v1`, FREELLMAPI_API_KEY: key,
  };
  const config = readWorkerConfig({ env, cwd: root });
  const logs = [];
  const runtime = () => new WorkerRuntime(config, { log: (line) => logs.push(line) });
  t.after(async () => {
    server.closeAllConnections(); await new Promise((done) => server.close(done));
    // This directory was created by this test; never delete a computed ancestor.
    assert.ok(resolve(root).startsWith(resolve(tmpdir()) + "\\") || resolve(root).startsWith(resolve(tmpdir()) + "/"));
    assert.ok(root.includes("fornai-worker-test-"));
    await rm(root, { recursive: true, force: true });
  });
  return { root, config, env, runtime, events, logs };
}

test("requires both credentials and ignores server .env.local by default", async (t) => {
  const f = await fixture(t);
  await writeFile(join(f.root, ".env.local"), `FORNAI_WORKER_TOKEN=${token}\nFREELLMAPI_API_KEY=${key}`);
  assert.throws(() => readWorkerConfig({ env: {}, cwd: f.root }), /FORNAI_WORKER_TOKEN/);
  assert.throws(() => readWorkerConfig({ env: { FORNAI_WORKER_TOKEN: token }, cwd: f.root }), /FREELLMAPI_API_KEY/);
  await writeFile(join(f.root, ".env.worker"), `FORNAI_WORKER_TOKEN=${token}\nFREELLMAPI_API_KEY=${key}`);
  assert.equal(readWorkerConfig({ env: {}, cwd: f.root }).freeLlmKey, key);
});

test("rejects credential-bearing or remote local-API URLs", () => {
  for (const url of ["http://user:pass@127.0.0.1:31415/v1", "https://untrusted.invalid/v1", "http://127.0.0.1:31415/v1?key=secret", "http://192.168.1.20:31415/v1"]) assert.throws(() => validateEndpoint(url, "FreeLLMAPI"));
  assert.throws(() => validateEndpoint("https://fornai.dev.attacker.invalid", "Fornai"));
  assert.equal(validateEndpoint("https://fornai.dev", "Fornai"), "https://fornai.dev");
});

test("401 preflight fails before claiming or invoking inference", async (t) => {
  const f = await fixture(t, { authFailure: true });
  await assert.rejects(f.runtime().run({ once: true }), /HTTP 401/);
  assert.equal(f.events.claims, 0); assert.equal(f.events.inference, 0);
});

test("local API auth failure also prevents job claim", async (t) => {
  const f = await fixture(t, { localAuthFailure: true });
  await assert.rejects(f.runtime().run({ once: true }), /HTTP 401/);
  assert.equal(f.events.claims, 0);
});

test("--check performs no heartbeat, claim or inference", async (t) => {
  const f = await fixture(t);
  await f.runtime().run({ check: true });
  assert.equal(f.events.claims, 0); assert.equal(f.events.inference, 0);
  assert.equal(f.events.remoteHeaders.length, 1);
});

test("forwards actual output and measured usage, keeping credentials on their own origins", async (t) => {
  const f = await fixture(t);
  await f.runtime().run({ once: true });
  const result = f.events.completions[0];
  assert.equal(result.status, "completed"); assert.equal(result.output, reply.choices[0].message.content);
  assert.deepEqual(result.usage, { promptTokens: 19, completionTokens: 8 }); assert.equal(result.model, reply.model);
  assert.equal(f.events.inference, 1);
  assert.equal(f.events.prompts[0].messages[1].content, "Propose a function. Do not run any commands.");
  assert.match(f.events.prompts[0].messages[0].content, /no repository/);
  assert.equal(f.events.prompts[0].tools, undefined);
  for (const headers of f.events.remoteHeaders) { assert.equal(headers.authorization, undefined); assert.ok(!JSON.stringify(headers).includes(key)); }
  for (const headers of f.events.localHeaders) { assert.equal(headers.authorization, `Bearer ${key}`); assert.equal(headers["x-fornai-worker-token"], undefined); }
  const receipts = await readdir(join(f.config.stateDir, "receipts"));
  const receipt = JSON.parse(await readFile(join(f.config.stateDir, "receipts", receipts[0]), "utf8"));
  assert.equal(receipt.receipt.rewardBaseUnits, "8");
  assert.ok(!JSON.stringify(receipt).includes(token)); assert.ok(!JSON.stringify(receipt).includes(key));
});

test("failed inference is reported failed, never completed, without exposing provider error", async (t) => {
  const f = await fixture(t, { inferenceFailure: true });
  await f.runtime().run({ once: true });
  assert.equal(f.events.completions[0].status, "failed");
  assert.deepEqual(f.events.completions[0].usage, { promptTokens: 0, completionTokens: 0 });
  assert.ok(!JSON.stringify(f.events.completions).includes(key));
});

test("settlement retry after restart does not invoke inference or claim again", async (t) => {
  const f = await fixture(t, { completionFailures: 1 });
  await assert.rejects(f.runtime().run({ once: true }), /HTTP 503/);
  const pending = JSON.parse(await readFile(join(f.config.stateDir, "pending.json"), "utf8"));
  assert.equal(pending.phase, "ready"); assert.equal(pending.payload.output, reply.choices[0].message.content);
  assert.ok(!JSON.stringify(pending).includes(key)); assert.ok(!JSON.stringify(pending).includes(token));
  await f.runtime().run({ once: true });
  assert.equal(f.events.inference, 1); assert.equal(f.events.claims, 1);
  assert.equal(f.events.completions.length, 2); assert.deepEqual(f.events.completions[0], f.events.completions[1]);
  await assert.rejects(readFile(join(f.config.stateDir, "pending.json")), /ENOENT/);
});

test("long inference renews its lease and never overlaps polling jobs", async (t) => {
  let runtime;
  const f = await fixture(t, { inferenceDelay: 350, jobs: 2, onComplete: (body) => { if (body.id === "job-2") runtime.stop(); } });
  runtime = f.runtime();
  await runtime.run();
  assert.equal(f.events.inference, 2); assert.equal(f.events.maxActive, 1); assert.equal(f.events.claims, 2);
  assert.ok(f.events.renewals >= 2);
});

test("shutdown aborts inference and settles failed instead of claiming another job", async (t) => {
  let runtime;
  const f = await fixture(t, { inferenceDelay: 400, onInference: () => setTimeout(() => runtime.stop(), 25) });
  runtime = f.runtime();
  await runtime.run();
  assert.equal(f.events.claims, 1); assert.equal(f.events.completions[0].status, "failed");
  assert.match(f.events.completions[0].output, /stopped/);
});

test("missing usage cannot be advertised as a completed metered job", async (t) => {
  const f = await fixture(t, { reply: { ...reply, usage: undefined } });
  await f.runtime().run({ once: true });
  assert.equal(f.events.completions[0].status, "failed");
});

test("redirects cannot forward worker credentials", async (t) => {
  const f = await fixture(t, { authRedirect: true });
  await assert.rejects(f.runtime().run({ check: true }), /unavailable/);
  assert.equal(f.events.remoteHeaders.length, 1); assert.equal(f.events.claims, 0);
});

test("crashed in-flight journal is settled failed without repeating inference", async (t) => {
  const f = await fixture(t, { completionFailures: 1 });
  await assert.rejects(f.runtime().run({ once: true }));
  const path = join(f.config.stateDir, "pending.json");
  const pending = JSON.parse(await readFile(path, "utf8"));
  pending.phase = "inference"; delete pending.payload;
  await writeFile(path, JSON.stringify(pending));
  await f.runtime().run({ once: true });
  assert.equal(f.events.inference, 1); assert.equal(f.events.claims, 1);
  assert.equal(f.events.completions[1].status, "failed");
  assert.match(f.events.completions[1].output, /not repeated/);
});

test("a second process owner cannot use the same state directory", async (t) => {
  const f = await fixture(t);
  const first = f.runtime(); const second = f.runtime();
  await first.acquireLock();
  try { await assert.rejects(second.run({ once: true }), /Another worker/); }
  finally { await first.releaseLock(); }
  assert.equal(f.events.claims, 0);
});
