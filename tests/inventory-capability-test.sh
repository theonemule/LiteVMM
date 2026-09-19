#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
node - <<'JS'
const fs=require('fs'); const src=fs.readFileSync(process.cwd()+'/www/app.js','utf8');
const a=src.indexOf('  function inventoryCapability'); const b=src.indexOf('  async function collectImages');
const body=src.slice(a,b);
const calls=[];
const state={service:{capabilities:['backup','replication-source','storage-backplane']},hostCatalog:{local:{node_id:'aa'},peers:[{node_id:'client184',name:'184'},{node_id:'down',name:'down'}]}};
const hostLabelForPeer=()=> 'local', abbreviatedNodeId=x=>x;
async function request(path,opts={}){ calls.push(`${opts.peerId||'local'} ${path}`);
  if(opts.peerId==='down') throw new Error('unreachable');
  if(path==='/') return {capabilities:['backup','replication-source','backplane-client']};
  if(opts.peerId==='client184' && path==='/replications/replicas') throw new Error('404 Capability is not installed');
  return [{vm:'x'}]; }
const f=new Function('state','request','hostLabelForPeer','abbreviatedNodeId', body+'; return {collectHostInventory,inventoryCapability};');
const {collectHostInventory,inventoryCapability}=f(state,request,hostLabelForPeer,abbreviatedNodeId);
(async()=>{
  const assert=require('assert');
  assert.equal(inventoryCapability('/replications/replicas'),'storage-backplane');
  assert.equal(inventoryCapability('/replications'),'replication-source');
  assert.equal(inventoryCapability('/backups/schedules'),'backup');
  assert.equal(inventoryCapability('/docker/images'),'docker');
  const r=await collectHostInventory('/replications/replicas');
  console.log('replicas rows:',r.rows.length,'errors:',JSON.stringify(r.errors));
  assert.equal(r.rows.length,1);                       // only local hosts replicas
  assert.ok(!calls.includes('client184 /replications/replicas')); // client peer skipped, never asked
  assert.equal(r.errors.length,1); assert.ok(r.errors[0].startsWith('down:')); // real outage still reported
  const s=await collectHostInventory('/replications');
  assert.equal(s.rows.length,2);                        // client peer still queried for sources
  assert.equal(calls.filter(c=>c==='client184 /').length,1); // capability probe cached
  console.log('inventory capability filtering: PASS');
})().catch(e=>{console.error('FAIL',e);process.exit(1)});
JS
