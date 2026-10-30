// Private stdin/stdout IPC with the native desktop app. Never run this adapter
// with stdout redirected to a log: credential messages belong only to its host.
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { readWorkerConfig, WorkerError, WorkerRuntime } from "./worker-runtime.mjs";

function friendly(message) {
  if (message.includes("Preflight OK")) return "Account Fornai e API locale collegati.";
  if (message.includes("Settlement acknowledged")) return "Risposta consegnata a Fornai. Ricevuta salvata.";
  if (message.includes("credential renewed")) return "Accesso all'account rinnovato automaticamente.";
  if (message.includes("retrying the durable settlement")) return "Connessione temporaneamente non disponibile. Riprovo automaticamente conservando la ricevuta.";
  if (message.includes("FreeLLMAPI request interrupted")) return "FreeLLMAPI non risponde. Controlla che sia avviata sul PC.";
  if (message.includes("Fornai request interrupted")) return "Fornai non è raggiungibile. Controlla la connessione Internet.";
  if (message.includes("HTTP 401") || message.includes("HTTP 403")) return message.startsWith("FreeLLMAPI") ? "Chiave FreeLLMAPI rifiutata. Verifica la chiave API unificata." : "Collega di nuovo il wallet per rinnovare l'accesso a Fornai.";
  if (message.includes("Another worker")) return "Un altro worker usa questa configurazione. Chiudilo prima di avviare una seconda copia.";
  return message;
}

export function createHostCredentialStore(send, { timeoutMs = 10000 } = {}) {
  const pending = new Map();
  return {
    async read() { return null; }, // Host supplies the newest decrypted token in env.
    write(saved) {
      return new Promise((resolve, reject) => {
        const id = randomUUID();
        const timer = setTimeout(() => { pending.delete(id); reject(new WorkerError("Il salvataggio sicuro della credenziale non è stato confermato.")); }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
        send({ type: "credential", id, workerToken: saved.token, wallet: saved.wallet });
      });
    },
    acknowledge(message) {
      if (message?.action !== "credential-saved" || typeof message.id !== "string") return false;
      const operation = pending.get(message.id);
      if (!operation) return false;
      pending.delete(message.id); clearTimeout(operation.timer);
      if (message.ok === true) operation.resolve();
      else operation.reject(new WorkerError("Impossibile salvare la credenziale nella protezione sicura del sistema."));
      return true;
    },
    close() {
      for (const operation of pending.values()) { clearTimeout(operation.timer); operation.reject(new WorkerError("L'app worker è stata chiusa.")); }
      pending.clear();
    },
  };
}

export async function runTrayWorker({ input = process.stdin, output = process.stdout, env = process.env } = {}) {
  const send = message => output.write(JSON.stringify(message) + "\n");
  let runtime;
  const credentialStore = createHostCredentialStore(send);
  const reader = createInterface({ input, crlfDelay: Infinity });
  let stopping = false;
  const stop = () => { stopping = true; runtime?.stop(); credentialStore.close(); };
  reader.on("line", line => {
    if (line.length > 65536) return;
    try {
      const message = JSON.parse(line);
      if (message.action === "stop") stop();
      else credentialStore.acknowledge(message);
    } catch { /* Reject malformed private IPC without echoing its contents. */ }
  });
  reader.on("close", stop);
  process.on("SIGINT", stop); process.on("SIGTERM", stop);
  try {
    send({ type: "status", state: "starting", message: "Connessione a Fornai e FreeLLMAPI…" });
    const config = readWorkerConfig({ env });
    runtime = new WorkerRuntime(config, { credentialStore, log: message => {
      if (message.includes("retrying the durable settlement")) send({ type: "status", state: "error", message: friendly(message), fatal: false });
      else send({ type: "log", message: friendly(message) });
    } });
    const heartbeat = runtime.heartbeat.bind(runtime);
    runtime.heartbeat = async (state = "ready") => {
      const result = await heartbeat(state);
      if (!stopping && state !== "offline") send({ type: "status", state: state === "running" ? "working" : "ready", message: state === "running" ? "Richiesta in elaborazione" : "Pronto a ricevere task" });
      return result;
    };
    const preflight = runtime.preflight.bind(runtime);
    runtime.preflight = async () => { await preflight(); send({ type: "status", state: "ready", message: "Pronto a ricevere task" }); };
    const runJob = runtime.runJob.bind(runtime);
    runtime.runJob = async claim => {
      send({ type: "status", state: "working", message: "Richiesta in elaborazione" });
      return runJob(claim);
    };
    const settle = runtime.settle.bind(runtime);
    runtime.settle = async record => {
      const receipt = await settle(record);
      send({ type: "receipt", jobId: receipt.jobId, status: receipt.status, currency: receipt.currency, rewardCredits: receipt.rewardCredits ?? "0" });
      if (!stopping) send({ type: "status", state: "ready", message: "Pronto a ricevere task" });
      return receipt;
    };
    if (stopping) runtime.stop();
    await runtime.run();
    await runtime.heartbeat("offline").catch(() => {});
    send({ type: "status", state: "paused", message: "Worker in pausa" });
    return 0;
  } catch (error) {
    // Known runtime messages never include remote response bodies or credentials.
    const message = error instanceof WorkerError ? friendly(error.message) : "Avvio non riuscito. Controlla la configurazione del worker.";
    send({ type: "status", state: "error", message, fatal: error instanceof WorkerError ? error.fatal : true });
    return 1;
  } finally {
    credentialStore.close(); reader.close();
    process.off("SIGINT", stop); process.off("SIGTERM", stop);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await runTrayWorker();
}
