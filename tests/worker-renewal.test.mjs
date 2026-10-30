// Copyright (c) 2026 mikeminer. All rights reserved.
// SPDX-License-Identifier: LicenseRef-Fornai-Proprietary

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WorkerRuntime } from "../scripts/worker-runtime.mjs";
const token=(address,days)=>Buffer.from(JSON.stringify({address,scope:"worker",expiresAt:new Date(Date.now()+days*86400000).toISOString()})).toString("base64url")+".signed-by-server";
test("scoped credential renews durably and is restored after restart",async()=>{
 const stateDir=await mkdtemp(join(tmpdir(),"fornai-renew-"));
 try{
 const config={stateDir,wallet:"owner",workerToken:token("owner",1),freeLlmKey:"local-key",apiUrl:"https://fornai.dev",freeLlmUrl:"http://127.0.0.1:31415/v1"};
 const runtime=new WorkerRuntime({...config},{log:()=>{}});const renewed=token("owner",7);
 runtime.request=async(kind,path,options)=>{assert.equal(path,"/api/worker/renew-token");assert.equal(options.body.wallet,"owner");assert.equal(options.body.protocolVersion,2);return {token:renewed};};
 await runtime.refreshCredential();assert.equal(runtime.config.workerToken,renewed);
 const restarted=new WorkerRuntime({...config},{log:()=>{}});await restarted.restoreCredential();assert.equal(restarted.config.workerToken,renewed);
 }finally{await rm(stateDir,{recursive:true,force:true});}
});
test("renewal cannot replace the authenticated owner",async()=>{
 const runtime=new WorkerRuntime({stateDir:tmpdir(),wallet:"owner",workerToken:token("owner",1),freeLlmKey:"local-key",apiUrl:"https://fornai.dev",freeLlmUrl:"http://127.0.0.1:31415/v1"},{log:()=>{}});
 runtime.request=async()=>({token:token("attacker",7)});
 await assert.rejects(runtime.refreshCredential(),/Invalid renewed/);
});
