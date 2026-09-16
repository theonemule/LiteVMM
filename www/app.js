(() => {
  // LiteVMM single-page console. This module owns client-side routing, rendering, and API calls.
  // Server state remains authoritative: UI actions call the Bash CGI API and re-render from its response.
  'use strict';

  const API = '/api';
  const state = {
    route: 'dashboard',
    service: null,
    activeService: null,
    cache: {},
    busy: false,
    pollers: { dashboard: null, detail: null },
    metricHistory: {},
    counters: {},
    remotePeerId: '',
    hostCatalog: { local: null, peers: [] },
  };

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const esc = (v = '') => String(v).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  const encodeForm = obj => {
    const p = new URLSearchParams();
    Object.entries(obj).forEach(([k,v]) => {
      if (v === undefined || v === null || v === '') return;
      if (Array.isArray(v)) v.forEach((x,i) => p.set(`${k}_${i}`, x));
      else p.set(k, String(v));
    });
    return p.toString();
  };
  const bytes = n => {
    n = Number(n || 0); if (!Number.isFinite(n)) return String(n || '');
    const u = ['B','KB','MB','GB','TB']; let i=0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return `${n < 10 && i ? n.toFixed(1) : Math.round(n)} ${u[i]}`;
  };
  const first = v => Array.isArray(v) ? v[0] : v;
  const lines = text => String(text || '').split(/\r?\n/).map(x => x.trim()).filter(Boolean);
  const shellQuote = v => `'${String(v ?? '').replace(/'/g, `'"'"'`)}'`;
  const commandLine = parts => parts.map(shellQuote).join(' ');
  const setPreview = (id, command) => { const el = $(id); if (el) el.textContent = command; };
  const stateBadge = s => {
    const x = String(s || 'unknown').toLowerCase();
    const cls = ['running','up'].includes(x) ? 'text-bg-success' : ['exited','stopped','dead'].includes(x) ? 'text-bg-secondary' : ['paused','restarting'].includes(x) ? 'text-bg-warning' : ['error','failed','degraded'].includes(x) ? 'text-bg-danger' : 'text-bg-light';
    return `<span class="badge rounded-pill ${cls} badge-state">${esc(s || 'unknown')}</span>`;
  };

  const validNodeId = id => /^[a-f0-9]{32}$/i.test(String(id || ''));
  const usablePeer = peer => Boolean(peer?.url && peer?.api_auth === 'basic' && validNodeId(peer.node_id));
  const hasCap = cap => Boolean((state.activeService || state.service)?.capabilities?.includes(cap));
  const routeCapability = route => ({vms:'qemu-kvm',networks:'qemu-kvm',containers:'docker',compose:'docker',backups:'backup'}[route] || '');
  const routeAllowed = route => !routeCapability(route) || hasCap(routeCapability(route));
  function updateCapabilityUI() {
    $$('[data-capability]').forEach(el=>el.classList.toggle('d-none',!hasCap(el.dataset.capability)));
    const profile=(state.activeService||state.service)?.profile||'unknown';
    const subtitle=$('#brandSubtitle'); if(subtitle) subtitle.textContent=profile==='virtualization'?'Virtualization platform':profile==='docker'?'Docker platform':profile==='backup'?'Backup receiver':'Minimal infrastructure';
  }
  const abbreviatedNodeId = id => `${String(id || '').slice(0,12)}…`;
  const hostRouteHash = (route, peerId = '') => {
    const targetRoute = route === 'cluster' && peerId ? 'dashboard' : (routes[route] ? route : 'dashboard');
    return `#${targetRoute}${peerId ? `?peer=${encodeURIComponent(peerId)}` : ''}`;
  };

  function buildHostCatalog(identity, peers) {
    const availablePeers = (Array.isArray(peers) ? peers : []).filter(usablePeer);
    const names = availablePeers.reduce((counts, peer) => {
      const name = String(peer.name || '').trim();
      if (name) counts.set(name, (counts.get(name) || 0) + 1);
      return counts;
    }, new Map());
    return {
      local: identity && typeof identity === 'object' ? identity : null,
      peers: availablePeers.map(peer => {
        const name = String(peer.name || '').trim();
        return { ...peer, label: name && names.get(name) === 1 ? name : `${name || 'Paired host'} · ${abbreviatedNodeId(peer.node_id)}` };
      }),
    };
  }

  function activeHost() {
    if (!state.remotePeerId) return { name: state.hostCatalog.local?.name || 'Local host', remote: false };
    const peer = state.hostCatalog.peers.find(candidate => candidate.node_id.toLowerCase() === state.remotePeerId);
    return { name: peer?.name || peer?.label || 'Paired host', remote: true };
  }

  function renderHostSelector() {
    const selector = $('#hostSelector');
    const indicator = $('#activeHostIndicator');
    if (!selector || !indicator) return;
    const localName = state.hostCatalog.local?.name || 'Local host';
    selector.innerHTML = `<option value="">${esc(localName)} (Local)</option>${state.hostCatalog.peers.map(peer => `<option value="${esc(peer.node_id)}">${esc(peer.label)}</option>`).join('')}`;
    selector.value = state.remotePeerId;
    if (selector.value !== state.remotePeerId) selector.value = '';
    const host = activeHost();
    indicator.textContent = host.name;
    indicator.classList.toggle('host-indicator-remote', host.remote);
    indicator.dataset.remote = host.remote ? 'Remote' : 'Local';
  }

  async function loadHostCatalog() {
    try {
      const local = {local:true};
      const [identity, peers] = await Promise.all([request('/cluster/identity', local), request('/cluster/peers', local)]);
      state.hostCatalog = buildHostCatalog(identity, peers);
    } catch {
      state.hostCatalog = { local: null, peers: [] };
    }
    renderHostSelector();
  }

  async function request(path, opts = {}) {
    const init = { method: opts.method || 'GET', credentials: 'same-origin', headers: { 'Accept': 'application/json', ...(opts.headers || {}) } };
    if (opts.signal) init.signal = opts.signal;
    if (opts.form) {
      init.headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
      init.body = encodeForm(opts.form);
    } else if (opts.body !== undefined) init.body = opts.body;
    const peerId = opts.peerId || state.remotePeerId;
    const useRemote = peerId && !opts.local && state.route !== 'cluster';
    const target = useRemote ? `${API}/cluster/peers/${encodeURIComponent(peerId)}/proxy?path=${encodeURIComponent(path)}` : API + path;
    const res = await fetch(target, init);
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!res.ok) {
      const detail = data && typeof data === 'object' && data.error ? data.error : (text || 'The server returned no diagnostic detail.');
      throw new Error(`${init.method} ${target} failed with HTTP ${res.status} ${res.statusText}: ${detail}`);
    }
    return data;
  }

  // Fetch does not expose upload-byte progress. File transfers use XHR so the
  // UI can report progress while all other API calls continue through request().
  function uploadFile(path, file, onProgress = () => {}) {
    const useRemote = state.remotePeerId && state.route !== 'cluster';
    const target = useRemote ? `${API}/cluster/peers/${encodeURIComponent(state.remotePeerId)}/proxy?path=${encodeURIComponent(path)}` : API + path;
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest(); xhr.open('PUT', target); xhr.withCredentials = true;
      xhr.setRequestHeader('Accept', 'application/json'); xhr.setRequestHeader('Content-Type', 'application/octet-stream');
      xhr.upload.onprogress = event => onProgress(event.loaded, event.total || file.size, event.lengthComputable);
      xhr.onerror = () => reject(new Error(`Upload failed before ${file.name} could be sent.`));
      xhr.onload = () => { let data = null; try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null; } catch { data = xhr.responseText; }
        if (xhr.status < 200 || xhr.status >= 300) { const detail = data && typeof data === 'object' && data.error ? data.error : (xhr.responseText || 'The server returned no diagnostic detail.'); reject(new Error(`Upload failed with HTTP ${xhr.status}: ${detail}`)); return; }
        onProgress(file.size, file.size, true); resolve(data);
      };
      xhr.send(file);
    });
  }
  function downloadFile(path, peerId = '') {
    const targetPeerId = peerId || state.remotePeerId;
    const useRemote = targetPeerId && state.route !== 'cluster';
    const target = useRemote ? `${API}/cluster/peers/${encodeURIComponent(targetPeerId)}/proxy?path=${encodeURIComponent(path)}` : API + path;
    window.open(target, '_blank', 'noopener');
  }

  function toast(message, title = 'LiteVMM') {
    $('#toastTitle').textContent = title;
    $('#toastBody').textContent = message;
    bootstrap.Toast.getOrCreateInstance($('#appToast'), { delay: 3500 }).show();
  }

  function lockActionItem(button, label) {
    const item = button?.closest('tr, .list-group-item') || button?.parentElement;
    const buttons = item ? $$('button', item) : [button];
    buttons.forEach(b => { b.disabled = true; b.setAttribute('aria-disabled', 'true'); });
    if (button) {
      button.setAttribute('aria-busy', 'true');
      button.innerHTML = `<span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span>${esc(label)}...`;
    }
    return () => buttons.forEach(b => { b.disabled = false; b.removeAttribute('aria-disabled'); b.removeAttribute('aria-busy'); });
  }

  function setConnection(ok, user) {
    $('#connectionDot').className = `status-dot ${ok ? 'bg-success' : 'bg-danger'}`;
    $('#connectionText').textContent = ok ? 'API connected' : 'API unavailable';
    $('#authUser').textContent = user ? `Basic auth · ${user}` : 'HTTP Basic authentication';
  }

  function vmCreateCommand(o) {
    const parts = ['/usr/local/bin/vmctl', 'create', o.name || 'NAME'];
    const opts = [
      ['--memory', o.memory_mb], ['--cpus', o.vcpus], ['--disk', o.disk_size], ['--disk-format', o.disk_format], ['--disk-bus', o.disk_bus],
      ['--iso', o.iso], ['--network', o.network], ['--bridge', o.network === 'bridge' ? o.bridge : ''], ['--overlay', o.network === 'overlay' ? o.overlay : ''], ['--vlan', ['bridge','overlay'].includes(o.network) ? o.vlan : ''], ['--nic-model', o.nic_model],
      ['--autostart', o.autostart], ['--firmware', o.firmware], ['--machine', o.machine], ['--cpu', o.cpu], ['--vnc-display', o.vnc_display],
      ['--vnc-bind', o.vnc_bind], ['--display', o.display], ['--boot', o.boot]
    ];
    opts.forEach(([k,v]) => { if (v !== undefined && v !== null && v !== '') parts.push(k, v); });
    const create = commandLine(parts);
    if (o.cloud_init_enabled === 'true') {
      const ci = ['/usr/local/bin/vmctl','cloud-init-set',o.name || 'NAME','--hostname',o.cloud_init_hostname || o.name || 'NAME'];
      return `${create}
${commandLine(ci)} < user-data`;
    }
    return create;
  }

  function containerCreateCommand(o) {
    const parts = ['/usr/local/bin/dockerctl', 'create', o.name || 'NAME', o.image || 'IMAGE'];
    [['--hostname', o.hostname], ['--restart', o.restart], ['--cpus', o.cpus], ['--memory', o.memory], ['--network', o.network], ['--user', o.user], ['--workdir', o.workdir], ['--entrypoint', o.entrypoint]].forEach(([k,v]) => { if (v) parts.push(k, v); });
    if (o.read_only === 'true') parts.push('--read-only');
    [['--env', o.env], ['--publish', o.publish], ['--volume', o.volume], ['--label', o.label]].forEach(([k,values]) => (values || []).forEach(v => parts.push(k, v)));
    if (o.cmd?.length) parts.push('--', ...o.cmd);
    return commandLine(parts);
  }

  function modal({eyebrow='', title='', body='', submitText='', submitClass='btn-primary', onSubmit=null, size='lg'}) {
    stopPoller('detail');
    const el = $('#formModal');
    const dialog = $('.modal-dialog', el);
    dialog.className = `modal-dialog modal-${size} modal-dialog-scrollable`;
    $('#modalEyebrow').textContent = eyebrow;
    $('#modalTitle').textContent = title;
    $('#modalBody').innerHTML = body;
    $('#modalFooter').innerHTML = `<button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Close</button>${submitText ? `<button id="modalSubmit" type="button" class="btn ${submitClass}">${esc(submitText)}</button>` : ''}`;
    const m = bootstrap.Modal.getOrCreateInstance(el);
    if (submitText && onSubmit) $('#modalSubmit').onclick = async () => {
      const btn = $('#modalSubmit'); const original = btn.innerHTML; btn.disabled = true; btn.setAttribute('aria-busy','true');
      btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1" aria-hidden="true"></span>Working…';
      $('#modalActionError', el)?.remove();
      try { await onSubmit(el, m); }
      catch (e) {
        const error = document.createElement('div'); error.id='modalActionError'; error.className='alert alert-danger mb-3'; error.setAttribute('role','alert');
        error.textContent = e?.message || 'The request failed without a diagnostic message.';
        $('#modalBody', el).prepend(error); toast(error.textContent, 'Request failed');
      } finally { btn.disabled = false; btn.removeAttribute('aria-busy'); btn.innerHTML = original; }
    };
    m.show();
    return m;
  }

  async function confirmAction(title, message, action, danger = true) {
    return new Promise(resolve => {
      modal({
        eyebrow: 'Confirm', title, size: 'sm', body: `<p class="mb-0">${esc(message)}</p>`,
        submitText: danger ? 'Delete' : 'Continue', submitClass: danger ? 'btn-danger' : 'btn-primary',
        onSubmit: async (_, m) => { await action(); m.hide(); resolve(true); }
      });
    });
  }

  function card(title, body, actions='') {
    return `<div class="card panel-card rounded-4"><div class="card-header bg-transparent border-0 px-3 px-md-4 pt-3 pt-md-4 pb-2 d-flex align-items-center gap-3"><div><h2 class="h5 section-title mb-1">${esc(title)}</h2></div><div class="ms-auto">${actions}</div></div><div class="card-body pt-1 px-3 px-md-4 pb-3 pb-md-4">${body}</div></div>`;
  }



  const percent = n => `${Math.max(0, Number(n || 0)).toFixed(1)}%`;
  const rateBytes = n => `${bytes(Math.max(0, Number(n || 0)))}/s`;
  const duration = seconds => { let n=Math.max(0,Number(seconds||0)); const d=Math.floor(n/86400); n%=86400; const h=Math.floor(n/3600); n%=3600; const m=Math.floor(n/60); return [d?`${d}d`:'',h?`${h}h`:'',m?`${m}m`:''].filter(Boolean).join(' ') || '<1m'; };

  function stopPoller(name) {
    if (state.pollers[name]) clearInterval(state.pollers[name]);
    state.pollers[name] = null;
  }

  function pushHistory(key, value, maxPoints = 60) {
    const v = Number(value);
    if (!Number.isFinite(v)) return state.metricHistory[key] || [];
    const a = state.metricHistory[key] || (state.metricHistory[key] = []);
    a.push(v); while (a.length > maxPoints) a.shift();
    return a;
  }

  function counterRate(key, value) {
    const now = performance.now() / 1000;
    const current = Number(value || 0);
    const prev = state.counters[key];
    state.counters[key] = { value: current, time: now };
    if (!prev || current < prev.value || now <= prev.time) return 0;
    return (current - prev.value) / (now - prev.time);
  }

  function meter(prefix, key, label, {progress=true} = {}) {
    return `<div class="col-sm-6 col-xl-3"><div class="resource-meter h-100 rounded-4 p-3">
      <div class="d-flex align-items-start gap-2"><div><div class="metric-label">${esc(label)}</div><div id="${prefix}-${key}-value" class="resource-value mt-2">—</div></div><div class="ms-auto small text-secondary" id="${prefix}-${key}-corner"></div></div>
      <div id="${prefix}-${key}-meta" class="small text-secondary mt-2 text-truncate">Waiting for sample…</div>
      ${progress ? `<div class="progress resource-progress mt-3" role="progressbar"><div id="${prefix}-${key}-bar" class="progress-bar" style="width:0%"></div></div>` : ''}
      <canvas id="${prefix}-${key}-chart" class="resource-chart mt-2" height="58"></canvas>
    </div></div>`;
  }

  function meterRow(prefix, spec) {
    return `<div class="row g-3">${spec.map(x => meter(prefix, x.key, x.label, x)).join('')}</div>`;
  }

  function drawSparkline(canvas, primary, secondary = null, fixedMax = null) {
    if (!canvas || !primary?.length) return;
    const rect = canvas.getBoundingClientRect();
    const dpr = Math.max(1, window.devicePixelRatio || 1);
    const w = Math.max(100, Math.floor(rect.width * dpr));
    const h = Math.max(40, Math.floor((Number(canvas.getAttribute('height')) || 58) * dpr));
    if (canvas.width !== w) canvas.width = w; if (canvas.height !== h) canvas.height = h;
    const ctx = canvas.getContext('2d'); ctx.clearRect(0,0,w,h);
    const primaryValues = Array.isArray(primary) ? primary : [];
    const secondaryValues = Array.isArray(secondary) ? secondary : [];
    const all = primaryValues.concat(secondaryValues);
    const max = Math.max(1, Number(fixedMax || 0), ...all.map(v => Number(v || 0) * 1.08));
    const css = getComputedStyle(document.documentElement);
    const primaryRgb = css.getPropertyValue('--bs-primary-rgb').trim() || '13,110,253';
    const secondaryRgb = css.getPropertyValue('--bs-success-rgb').trim() || '25,135,84';
    const plot = (values, rgb) => {
      if (!values?.length) return;
      ctx.beginPath();
      values.forEach((v,i) => {
        const x = values.length === 1 ? w : (i/(values.length-1))*w;
        const y = h - Math.min(max, Math.max(0, Number(v||0))) / max * (h-4) - 2;
        if (i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
      });
      ctx.strokeStyle = `rgba(${rgb},.95)`; ctx.lineWidth = Math.max(1.5, 1.5*dpr); ctx.lineJoin='round'; ctx.lineCap='round'; ctx.stroke();
    };
    plot(primary, primaryRgb); if (secondary) plot(secondary, secondaryRgb);
  }

  function updateMeter(prefix, key, {value='—', meta='', corner='', percentValue=null, historyValue=null, history2=null, fixedMax=null}) {
    const valueEl = $(`#${prefix}-${key}-value`); if (!valueEl) return;
    valueEl.textContent = value;
    const metaEl = $(`#${prefix}-${key}-meta`); if (metaEl) metaEl.textContent = meta;
    const cornerEl = $(`#${prefix}-${key}-corner`); if (cornerEl) cornerEl.textContent = corner;
    const bar = $(`#${prefix}-${key}-bar`);
    if (bar && percentValue !== null && Number.isFinite(Number(percentValue))) bar.style.width = `${Math.max(0,Math.min(100,Number(percentValue)))}%`;
    const h1 = historyValue === null ? [] : pushHistory(`${prefix}.${key}.1`, historyValue);
    const h2 = history2 === null ? null : pushHistory(`${prefix}.${key}.2`, history2);
    requestAnimationFrame(() => drawSparkline($(`#${prefix}-${key}-chart`), h1, h2, fixedMax));
  }

  function renderHostMetrics(m) {
    if (!m) return;
    const rxRate = counterRate('host.net.rx', m.network?.rx_bytes);
    const txRate = counterRate('host.net.tx', m.network?.tx_bytes);
    updateMeter('host','cpu',{value:percent(m.cpu?.utilization_percent),meta:`${m.cpu?.logical_cpus || 0} logical CPUs · load ${Number(m.cpu?.load1||0).toFixed(2)}`,percentValue:m.cpu?.utilization_percent,historyValue:m.cpu?.utilization_percent,fixedMax:100});
    updateMeter('host','memory',{value:percent(m.memory?.utilization_percent),meta:`${bytes(m.memory?.used_bytes)} of ${bytes(m.memory?.total_bytes)}`,percentValue:m.memory?.utilization_percent,historyValue:m.memory?.utilization_percent,fixedMax:100});
    updateMeter('host','disk',{value:percent(m.disk?.utilization_percent),meta:`${bytes(m.disk?.used_bytes)} of ${bytes(m.disk?.total_bytes)} · ${m.disk?.path || ''}`,percentValue:m.disk?.utilization_percent,historyValue:m.disk?.utilization_percent,fixedMax:100});
    updateMeter('host','network',{value:`↓ ${rateBytes(rxRate)}`,meta:`↑ ${rateBytes(txRate)} · cumulative ${bytes((m.network?.rx_bytes||0)+(m.network?.tx_bytes||0))}`,corner:'RX / TX',historyValue:rxRate,history2:txRate});
    const warning=$('#kvmWarning'); if(warning) warning.classList.toggle('d-none', m.virtualization?.kvm_available !== false);
  }

  function renderVMMetrics(m, name) {
    if (!m) return;
    const prefix='vmmetric';
    updateMeter(prefix,'cpu',{value:percent(m.cpu?.utilization_percent),meta:`${Number(m.cpu?.process_percent_one_core||0).toFixed(1)}% host-core equivalent · ${m.cpu?.allocated_vcpus||0} vCPU`,percentValue:m.cpu?.utilization_percent,historyValue:m.cpu?.utilization_percent,fixedMax:100});
    updateMeter(prefix,'memory',{value:percent(m.memory?.utilization_percent),meta:`${bytes(m.memory?.host_rss_bytes)} RSS of ${bytes(m.memory?.allocated_bytes)} configured`,percentValue:m.memory?.utilization_percent,historyValue:m.memory?.utilization_percent,fixedMax:100});
    updateMeter(prefix,'disk',{value:percent(m.disk?.utilization_percent),meta:`${bytes(m.disk?.host_allocated_bytes)} host allocated of ${bytes(m.disk?.virtual_bytes)} virtual`,percentValue:m.disk?.utilization_percent,historyValue:m.disk?.utilization_percent,fixedMax:100});
    if (m.network?.available) {
      const rx=counterRate(`vm.${name}.rx`,m.network.rx_bytes), tx=counterRate(`vm.${name}.tx`,m.network.tx_bytes);
      updateMeter(prefix,'network',{value:`↓ ${rateBytes(rx)}`,meta:`↑ ${rateBytes(tx)} · bridged interface counters`,corner:'RX / TX',historyValue:rx,history2:tx});
    } else updateMeter(prefix,'network',{value:'Unavailable',meta:m.network?.note || 'Network counters unavailable for this VM',historyValue:0,history2:0});
  }

  function renderContainerMetrics(m, name) {
    if (!m) return;
    const prefix='ctrmetric';
    const rx=counterRate(`ctr.${name}.rx`,m.network?.rx_bytes), tx=counterRate(`ctr.${name}.tx`,m.network?.tx_bytes);
    updateMeter(prefix,'cpu',{value:percent(m.cpu?.utilization_percent),meta:`${Number(m.cpu?.docker_percent||0).toFixed(1)}% Docker CPU · ${Number(m.cpu?.allocated_cpus||0).toFixed(2)} CPUs available`,percentValue:m.cpu?.utilization_percent,historyValue:m.cpu?.utilization_percent,fixedMax:100});
    updateMeter(prefix,'memory',{value:percent(m.memory?.utilization_percent),meta:`${bytes(m.memory?.used_bytes)} of ${bytes(m.memory?.effective_limit_bytes)}`,percentValue:m.memory?.utilization_percent,historyValue:m.memory?.utilization_percent,fixedMax:100});
    updateMeter(prefix,'disk',{value:bytes(m.disk?.writable_layer_bytes),meta:`writable layer · ${bytes(m.disk?.rootfs_bytes)} rootfs`,historyValue:m.disk?.writable_layer_bytes});
    updateMeter(prefix,'network',{value:`↓ ${rateBytes(rx)}`,meta:`↑ ${rateBytes(tx)} · Docker network I/O`,corner:'RX / TX',historyValue:rx,history2:tx});
  }

  function startDashboardMetrics() {
    stopPoller('dashboard');
    state.pollers.dashboard = setInterval(async () => {
      if (state.route !== 'dashboard') return stopPoller('dashboard');
      try { const m=await request('/metrics'); state.cache.hostMetrics=m; renderHostMetrics(m); } catch(e) { setConnection(false,state.service?.user); }
    }, 5000);
  }

  function startDetailMetrics(path, renderer) {
    stopPoller('detail');
    state.pollers.detail = setInterval(async () => {
      if (!$('#formModal')?.classList.contains('show')) return stopPoller('detail');
      try { renderer(await request(path)); } catch { /* resource may have stopped or disappeared */ }
    }, 5000);
  }
  function table(headers, rows, empty='Nothing here yet.') {
    if (!rows.length) return `<div class="empty-state"><div class="empty-glyph">·</div><div>${esc(empty)}</div></div>`;
    return `<div class="table-responsive"><table class="table table-hover align-middle mb-0"><thead><tr>${headers.map(h=>`<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table></div>`;
  }

  async function loadDashboard() {
    const results = await Promise.allSettled([
      request('/vms'), request('/docker/containers'), request('/images'), request('/docker/images'), request('/docker/networks'), request('/docker/volumes'), request('/metrics'), request('/system'), request('/backups')
    ]);
    const val = i => results[i].status === 'fulfilled' ? results[i].value : [];
    state.cache.vms = val(0); state.cache.containers = val(1); state.cache.vmImages = val(2); state.cache.dockerImages = val(3); state.cache.dockerNetworks = val(4); state.cache.volumes = val(5);
    state.cache.hostMetrics = results[6].status === 'fulfilled' ? results[6].value : null;
    state.cache.systemInfo = results[7].status === 'fulfilled' ? results[7].value : null;
    state.cache.backups = results[8].status === 'fulfilled' ? results[8].value : [];
    const runningVMs = state.cache.vms.filter(v => v.state === 'running').length;
    const runningContainers = state.cache.containers.filter(c => String(c.State || c.state || '').toLowerCase() === 'running').length;
    $('#view').innerHTML = `
      <div class="row g-3 mb-4">
        ${hasCap('qemu-kvm') ? `${metric('Virtual machines', state.cache.vms.length, `${runningVMs} running`)}${metric('VM images', state.cache.vmImages.length, 'shared install media')}${metric('Backups', state.cache.backups.length, 'local archives')}${metric('Profile', 'Virtualization', 'QEMU/KVM + backups')}` : ''}
        ${hasCap('docker') ? `${metric('Containers', state.cache.containers.length, `${runningContainers} running`)}${metric('Docker images', state.cache.dockerImages.length, 'daemon inventory')}${metric('Docker networks', state.cache.dockerNetworks.length, 'daemon networks')}${metric('Volumes', state.cache.volumes.length, 'persistent volumes')}` : ''}
        ${hasCap('backup-receiver') ? `${metric('Received backups', state.cache.backups.length, 'stored archives')}${metric('Paired hosts', state.hostCatalog.peers.length, 'trusted senders')}${metric('Profile', 'Backup', 'receiver-only node')}${metric('API port', (state.activeService||state.service)?.port||'', (state.activeService||state.service)?.tls_enabled?'HTTPS':'HTTP')}` : ''}
      </div>
      ${state.cache.hostMetrics?.virtualization?.kvm_available === false ? '<div id="kvmWarning" class="alert alert-warning mb-4"><strong>KVM acceleration is unavailable.</strong> New VMs will not start in slow software emulation unless you explicitly opt in. Expose <span class="mono">/dev/kvm</span> to this host for nested VM performance.</div>' : ''}
      <div class="mb-4">${card('Host resources', meterRow('host',[
        {key:'cpu',label:'CPU'}, {key:'memory',label:'Memory'}, {key:'disk',label:'Storage'}, {key:'network',label:'Network',progress:false}
      ]), '<span class="small text-secondary">5 second refresh</span>')}</div>
      <div class="row g-3">
        <div class="col-xl-7">${card('Compute', computeSummary())}</div>
        <div class="col-xl-5">${card('Platform', platformSummary())}</div>
      </div>
      <div class="mt-4">${card('Host diagnostics', `<div class="d-flex flex-column flex-sm-row align-items-sm-center justify-content-between gap-3"><div><div class="fw-semibold">Administrative tools</div><div class="small text-secondary">Review the tools enabled by this installation profile.</div></div><div class="d-flex flex-wrap gap-2">${hasCap('host-terminal')?'<button class="btn btn-primary" id="overviewHostTerminalBtn">Launch host terminal</button>':''}${hasCap('files')?'<button class="btn btn-outline-primary" id="overviewFileBrowserBtn">File browser</button>':''}<button class="btn btn-outline-secondary" id="overviewLogsBtn">View service logs</button></div></div>`)}</div>`;
    if (state.cache.hostMetrics) renderHostMetrics(state.cache.hostMetrics);
    startDashboardMetrics();
    $('#overviewHostTerminalBtn')?.addEventListener('click',openHostTerminal);
    $('#overviewFileBrowserBtn')?.addEventListener('click',()=>window.open('/files.html','vmapi-file-browser','noopener'));
    $('#overviewLogsBtn').onclick=openHostLogs;
  }

  async function openHostTerminal(){
    try {
      const session=await request('/host/terminal/session',{method:'POST',form:{}});
      window.open(session.url,'vmapi-host-terminal','noopener');
    } catch(e) { toast(e.message,'Host terminal failed'); }
  }

  async function openHostLogs(){
    const render=items=>table(['Source','Message'],items.map(x=>`<tr><td><span class="badge text-bg-secondary">${esc(x.source)}</span></td><td class="mono small text-break">${esc(x.message)}</td></tr>`),'No readable diagnostic logs.');
    modal({eyebrow:'Host diagnostics',title:'Service logs',size:'xl',body:`<div class="d-flex flex-column flex-sm-row gap-2 mb-3"><select id="hostLogSource" class="form-select form-select-sm" style="max-width:16rem"><option value="all">All sources</option><option value="system">System</option><option value="overlay">Overlay / GOST</option><option value="docker">Docker</option><option value="fcgi">API / fcgiwrap</option><option value="ttyd">Terminal broker</option><option value="websockify">VM console broker</option></select><button id="refreshHostLogsBtn" class="btn btn-sm btn-outline-secondary" type="button">Refresh</button></div><div id="hostLogTable">Loading logs...</div>`});
    const el=$('#formModal');
    const load=async()=>{const target=$('#hostLogTable',el);target.innerHTML='<div class="text-secondary small">Loading logs...</div>';try{target.innerHTML=render(await request(`/logs?source=${encodeURIComponent($('#hostLogSource',el).value)}&limit=500`));}catch(e){target.innerHTML=`<div class="alert alert-danger mb-0">${esc(e.message)}</div>`;}};
    $('#hostLogSource',el).onchange=load;
    $('#refreshHostLogsBtn',el).onclick=load;
    await load();
  }

  function metric(label, value, note) {
    return `<div class="col-6 col-xl-3"><div class="card metric-card rounded-4"><div class="card-body p-3 p-md-4 d-flex flex-column justify-content-between"><div class="metric-label">${esc(label)}</div><div><div class="metric-value fw-semibold">${esc(value)}</div><div class="small text-secondary mt-2">${esc(note)}</div></div></div></div></div>`;
  }

  function computeSummary() {
    const vms = (state.cache.vms || []).slice(0,5);
    const containers = (state.cache.containers || []).slice(0,5);
    const lines = [
      ...vms.map(v => `<div class="list-group-item d-flex align-items-center gap-3"><span class="badge text-bg-dark">VM</span><span class="resource-name flex-grow-1">${esc(v.name)}</span>${stateBadge(v.state)}</div>`),
      ...containers.map(c => `<div class="list-group-item d-flex align-items-center gap-3"><span class="badge text-bg-light">CTR</span><span class="resource-name flex-grow-1">${esc(c.Names || c.Name || '')}</span>${stateBadge(c.State || '')}</div>`)
    ];
    return lines.length ? `<div class="list-group list-group-flush list-compact">${lines.join('')}</div>` : `<div class="empty-state py-5">Create a VM or container to get started.</div>`;
  }

  function platformSummary() {
    const svc = state.service || {}; const sys=state.cache.systemInfo||{}; const host=sys.host||{}; const os=sys.os||{}; const net=sys.network||{}; const comp=sys.components||{};
    return `<dl class="row mb-3 small">
      <dt class="col-5 text-secondary">Host</dt><dd class="col-7 mono">${esc(host.hostname || '')}</dd>
      <dt class="col-5 text-secondary">Operating system</dt><dd class="col-7">${esc(os.pretty_name || '')}</dd>
      <dt class="col-5 text-secondary">Kernel</dt><dd class="col-7 mono">${esc(host.kernel || '')}</dd>
      <dt class="col-5 text-secondary">Primary IP</dt><dd class="col-7 mono">${esc(net.primary_ipv4 || '')}</dd>
      <dt class="col-5 text-secondary">LiteVMM</dt><dd class="col-7 mono">${esc(comp.litevmm || svc.version || '')}</dd>
      <dt class="col-5 text-secondary">QEMU</dt><dd class="col-7 text-truncate" title="${esc(comp.qemu||'')}">${esc(comp.qemu || 'Unavailable')}</dd>
      <dt class="col-5 text-secondary">Docker</dt><dd class="col-7 text-truncate" title="${esc(comp.docker||'')}">${esc(comp.docker || 'Unavailable')}</dd>
      <dt class="col-5 text-secondary">Uptime</dt><dd class="col-7 mb-0">${duration(host.uptime_seconds)}</dd>
    </dl><a class="btn btn-sm btn-outline-primary" href="#system${state.remotePeerId?`?peer=${encodeURIComponent(state.remotePeerId)}`:''}">Full system information</a>`;
  }

  function systemDl(rows) {
    return `<dl class="row small mb-0">${rows.map(([k,v,mono=false])=>`<dt class="col-md-4 text-secondary">${esc(k)}</dt><dd class="col-md-8 ${mono?'mono text-break':''}">${esc(v ?? '')}</dd>`).join('')}</dl>`;
  }

  async function loadSystemInfo() {
    const info=await request('/system'); state.cache.systemInfo=info;
    const host=info.host||{}, os=info.os||{}, hw=info.hardware||{}, net=info.network||{}, storage=info.storage||{}, comp=info.components||{}, services=info.services||{};
    const interfaces=(net.interfaces||[]).map(i=>{const addrs=(i.addr_info||[]).map(a=>`${a.local||''}/${a.prefixlen??''} (${a.family||''})`).join('<br>');return `<tr><td class="mono">${esc(i.ifname||'')}</td><td>${esc(i.operstate||'')}</td><td class="mono small">${addrs||'—'}</td><td class="mono small">${esc(i.address||'')}</td><td>${esc(i.mtu||'')}</td></tr>`;});
    const routes=(net.routes||[]).map(r=>`<tr><td class="mono">${esc(r.dst||'default')}</td><td class="mono">${esc(r.gateway||'')}</td><td class="mono">${esc(r.dev||'')}</td><td>${esc(r.metric??'')}</td></tr>`);
    const mounts=(storage.mounts?.filesystems||[]).map(m=>`<tr><td class="mono text-break">${esc(m.target||'')}</td><td class="mono text-break">${esc(m.source||'')}</td><td>${esc(m.fstype||'')}</td><td>${bytes(m.size)}</td><td>${bytes(m.used)}</td><td>${bytes(m.avail)}</td></tr>`);
    const disks=(storage.block_devices?.blockdevices||[]).map(d=>`<tr><td class="mono">${esc(d.name||'')}</td><td>${esc(d.type||'')}</td><td>${bytes(d.size)}</td><td>${esc(d.model||'')}</td><td class="mono">${esc((d.mountpoints||[]).filter(Boolean).join(', '))}</td></tr>`);
    const components=Object.entries(comp).map(([k,v])=>`<tr><td>${esc(k.replaceAll('_',' '))}</td><td class="mono small text-break">${esc(v||'Not installed')}</td></tr>`);
    const serviceRows=Object.entries(services).map(([k,v])=>`<tr><td class="mono">${esc(k)}</td><td>${stateBadge(v)}</td></tr>`);
    $('#view').innerHTML=`<div class="row g-3 mb-3"><div class="col-xl-6">${card('Host and operating system',systemDl([['Hostname',host.hostname,true],['FQDN',host.fqdn,true],['Operating system',os.pretty_name],['Kernel',host.kernel,true],['Architecture',host.architecture],['Timezone',host.timezone],['Virtualization host',host.virtualization_type||'bare metal'],['Uptime',duration(host.uptime_seconds)],['Machine ID',host.machine_id,true]]))}</div><div class="col-xl-6">${card('Hardware',systemDl([['CPU',hw.cpu_model],['Logical CPUs',hw.logical_cpus],['Sockets',hw.sockets],['Cores per socket',hw.cores_per_socket],['Threads per core',hw.threads_per_core],['RAM',bytes(hw.memory_total_bytes)],['Available RAM',bytes(hw.memory_available_bytes)],['Swap',bytes(hw.swap_total_bytes)],['KVM acceleration',hw.kvm_available?'Available':'Unavailable']]))}</div></div>
      <div class="row g-3 mb-3"><div class="col-xl-6">${card('Network summary',systemDl([['Primary IPv4',net.primary_ipv4,true],['Default gateway',net.default_gateway,true],['DNS',(net.dns||[]).join(', '),true]]))}</div><div class="col-xl-6">${card('Storage roots',systemDl([['VM configuration',storage.vm_root,true],['Virtual disks',storage.disk_root,true],['ISO media',storage.iso_root,true]]))}</div></div>
      <div class="mb-3">${card('Network interfaces',table(['Interface','State','Addresses','MAC','MTU'],interfaces,'No interfaces detected.'))}</div>
      <div class="mb-3">${card('Routes',table(['Destination','Gateway','Interface','Metric'],routes,'No routes detected.'))}</div>
      <div class="mb-3">${card('Filesystems',table(['Mount','Source','Type','Size','Used','Available'],mounts,'No mounted filesystems detected.'))}</div>
      <div class="mb-3">${card('Block devices',table(['Device','Type','Size','Model','Mounts'],disks,'No block devices detected.'))}</div>
      <div class="row g-3 mb-3"><div class="col-xl-7">${card('Component versions',table(['Component','Version'],components,'No component versions reported.'))}</div><div class="col-xl-5">${card('Service state',table(['Service','State'],serviceRows,'No service state reported.'))}</div></div>
      <div>${card('Technical dump',`<div class="small text-secondary mb-2">Raw system inventory returned by the host API.</div><pre class="code-panel mb-0" style="max-height:32rem;overflow:auto">${esc(JSON.stringify(info,null,2))}</pre>`)}</div>`;
  }

  async function loadVMs() {
    const vms = await request('/vms');
    const details = await Promise.all(vms.map(async v => { try { return await request(`/vms/${encodeURIComponent(v.name)}`); } catch { return v; } }));
    state.cache.vms = details;
    const rows = details.map(v => {
      const c = v.config || {};
      return `<tr><td><div class="resource-name">${esc(v.name)}</div><div class="small text-secondary mono">${esc(c.UUID || '')}</div></td><td>${stateBadge(v.state)}</td><td>${esc(c.VCPUS ?? '')}</td><td>${c.MEMORY_MB ? `${esc(c.MEMORY_MB)} MB` : ''}</td><td>${esc(c.FIRMWARE || '')}</td><td><div class="action-row">
        <button class="btn btn-sm btn-outline-secondary" data-vm-details="${esc(v.name)}">Edit</button><button class="btn btn-sm btn-outline-secondary" data-vm-backups="${esc(v.name)}">Backups</button>
        ${v.state === 'running' ? `<button class="btn btn-sm btn-outline-primary" data-vm-console="${esc(v.name)}">Console</button><button class="btn btn-sm btn-outline-success" data-vm-shutdown="${esc(v.name)}">Shutdown</button><button class="btn btn-sm btn-outline-secondary" data-vm-restart="${esc(v.name)}">Restart</button><button class="btn btn-sm btn-outline-warning" data-vm-stop="${esc(v.name)}">Power off</button><button class="btn btn-sm btn-outline-danger" data-vm-reboot="${esc(v.name)}">Reset</button>` : `<button class="btn btn-sm btn-outline-success" data-vm-start="${esc(v.name)}">Start</button><button class="btn btn-sm btn-outline-secondary" data-vm-migrate="${esc(v.name)}">Migrate</button>`}
        <button class="btn btn-sm btn-outline-danger" data-vm-delete="${esc(v.name)}">Delete</button>
      </div></td></tr>`;
    });
    $('#view').innerHTML = card('Virtual machines', table(['Name','State','vCPU','Memory','Firmware',''], rows, 'No virtual machines have been created.'), `<button class="btn btn-sm btn-outline-secondary me-2" id="vmDiskStorageBtn">Disk storage</button><button class="btn btn-sm btn-outline-secondary me-2" id="isoMediaBtn">ISO media</button><button class="btn btn-sm btn-outline-secondary me-2" id="storageLocationsBtn">Storage locations</button><button class="btn btn-sm btn-primary" id="createVmBtn">Create VM</button>`);
    $('#createVmBtn').onclick = openCreateVM;
    $('#vmDiskStorageBtn').onclick = openVMDiskStorage;
    $('#isoMediaBtn').onclick = openISOMediaLibrary;
    $('#storageLocationsBtn').onclick = openStorageLocations;
    $$('[data-vm-start]').forEach(b => b.onclick = () => lifecycleVM(b.dataset.vmStart, 'start'));
    $$('[data-vm-stop]').forEach(b => b.onclick = () => lifecycleVM(b.dataset.vmStop, 'stop'));
    $$('[data-vm-shutdown]').forEach(b => b.onclick = () => lifecycleVM(b.dataset.vmShutdown, 'shutdown'));
    $$('[data-vm-restart]').forEach(b => b.onclick = () => lifecycleVM(b.dataset.vmRestart, 'restart'));
    $$('[data-vm-reboot]').forEach(b => b.onclick = () => lifecycleVM(b.dataset.vmReboot, 'reboot'));
    $$('[data-vm-console]').forEach(b => b.onclick = () => openConsole(b.dataset.vmConsole));
    $$('[data-vm-migrate]').forEach(b => b.onclick = () => openMigrateVM(b.dataset.vmMigrate));
    $$('[data-vm-delete]').forEach(b => b.onclick = () => confirmAction('Delete VM', `Delete ${b.dataset.vmDelete} and its VM directory?`, async () => { await request(`/vms/${encodeURIComponent(b.dataset.vmDelete)}`, {method:'DELETE'}); await renderRoute(); }));
    $$('[data-vm-details]').forEach(b => b.onclick = () => openVMDetails(b.dataset.vmDetails));
    $$('[data-vm-backups]').forEach(b => b.onclick = () => openVMBackups(b.dataset.vmBackups));
  }

  async function lifecycleVM(name, action) {
    const verbs={start:'Starting',stop:'Powering off',shutdown:'Shutting down',restart:'Restarting',reboot:'Resetting'}; const verb=verbs[action]||'Working';
    const button = $$(`[data-vm-${action}]`).find(candidate => candidate.getAttribute(`data-vm-${action}`) === name);
    const originalLabel = button?.textContent || '';
    const unlock = lockActionItem(button, verb);
    toast(`${name}: ${verb.toLowerCase()}...`, 'VM action in progress');
    try {
      await request(`/vms/${encodeURIComponent(name)}/${action}`, { method:'POST' });
      toast(`${name}: ${verb.toLowerCase()} complete`);
      await renderRoute();
    } catch (e) {
      unlock();
      if (button) button.textContent = originalLabel;
      toast(e.message, 'VM action failed');
      await renderRoute();
    }
  }

  async function openConsole(name) {
    try {
      const session = await request(`/vms/${encodeURIComponent(name)}/console/session`, { method:'POST', form:{open:'1'} });
      toast(`${name}: console opened`);
      setTimeout(() => window.open(session.url, `vmapi-console-${name}`, 'noopener'), 1500);
    } catch (e) { toast(e.message, 'Console failed'); }
  }

  async function openMigrateVM(name) {
    const peers = await request('/cluster/peers');
    const options = peers.filter(peer => peer.url).map(peer => `<option value="${esc(peer.node_id)}">${esc(peer.name)} (${esc(peer.url)})</option>`).join('');
    modal({eyebrow:'Cluster migration',title:`Migrate ${name}`,submitText:'Migrate VM',submitClass:'btn-warning',body:`<form id="migrateForm"><label class="form-label">Destination peer</label><select name="node_id" class="form-select" required><option value="">Select a configured peer</option>${options}</select><div class="form-text">The stopped VM is copied to the peer and removed here only after its import succeeds.</div></form>`,onSubmit:async(el,m)=>{const nodeId=new FormData($('#migrateForm',el)).get('node_id');if(!nodeId)throw new Error('Select a peer with an API endpoint.');await request('/cluster/migrate',{method:'POST',form:{vm:name,node_id:nodeId}});m.hide();toast(`${name}: migration completed`);await renderRoute();}});
  }

  async function openCreateVM() {
    const [images, nets, overlays] = await Promise.all([request('/images'), request('/networks'), request('/overlays').catch(()=>[])]);
    const imgOpts = [`<option value="">None</option>`, ...images.map(i=>`<option value="${esc(i.name)}">${esc(i.name)}</option>`)].join('');
    const bridges = (nets.bridges || []).map(b=>`<option value="${esc(b)}">${esc(b)}</option>`).join('');
    const overlayOptions = (overlays || []).map(o=>`<option value="${esc(o.name)}">${esc(o.name)} · ${esc(o.bridge)}</option>`).join('');
    modal({eyebrow:'QEMU / KVM', title:'Create virtual machine', submitText:'Create VM', body:`
      <form id="vmCreateForm">
        <div class="form-section"><div class="form-section-title">Identity and compute</div><div class="row g-3">
          <div class="col-md-6"><label class="form-label">Name</label><input name="name" class="form-control" required placeholder="debian01"></div>
          <div class="col-6 col-md-3"><label class="form-label">vCPUs</label><select name="vcpus" class="form-select">${selectOptions(Array.from({length:16},(_,i)=>String(i+1)), '2')}</select></div>
          <div class="col-6 col-md-3"><label class="form-label">Memory MB</label><select name="memory_mb" class="form-select">${selectOptions(['256','512','1024','2048','4096','8192','16384'], '2048')}</select></div>
        </div></div>
        <div class="form-section"><div class="form-section-title">Storage and boot</div><div class="row g-3">
          <div class="col-md-4"><label class="form-label">Initial disk</label><input name="disk_size" class="form-control" value="40G"></div>
          <div class="col-md-4"><label class="form-label">Disk format</label><select name="disk_format" class="form-select"><option>qcow2</option><option>raw</option></select></div>
          <div class="col-md-4"><label class="form-label">Disk bus</label><select name="disk_bus" class="form-select"><option>virtio</option><option>sata</option><option>scsi</option></select></div>
          <div class="col-md-8"><label class="form-label">Install image</label><select name="iso" class="form-select">${imgOpts}</select></div>
          <div class="col-md-4"><label class="form-label">Firmware</label><select name="firmware" class="form-select"><option value="bios">BIOS</option><option value="uefi">UEFI</option></select></div>
        </div></div>
        <div class="form-section"><div class="form-section-title">Networking and display</div><div class="row g-3">
          <div class="col-md-4"><label class="form-label">Network</label><select name="network" id="vmNetMode" class="form-select"><option value="nat">NAT</option><option value="bridge">Bridge</option><option value="overlay">Overlay</option><option value="none">None</option></select></div>
          <div class="col-md-4" id="vmBridgeWrap"><label class="form-label">Bridge</label><select name="bridge" id="vmBridge" class="form-select"><option value="">Select bridge</option>${bridges}</select></div>
          <div class="col-md-4 d-none" id="vmOverlayWrap"><label class="form-label">Overlay network</label><select name="overlay" id="vmOverlay" class="form-select"><option value="">Select overlay</option>${overlayOptions}</select><div class="form-text">Only paired-node Layer-2 overlays appear here.</div></div>
          <div class="col-md-4"><label class="form-label">NIC model</label><select name="nic_model" class="form-select"><option>virtio-net-pci</option><option>e1000e</option><option>e1000</option><option>rtl8139</option></select></div>
          <div class="col-md-4" id="vmVlanWrap"><label class="form-label">VLAN ID</label><input name="vlan" type="number" min="1" max="4094" class="form-control" placeholder="Untagged"><div class="form-text">Optional access VLAN on a bridge or overlay.</div></div>
          <div class="col-md-4"><label class="form-label">Display</label><select name="display" class="form-select"><option value="vnc">VNC</option><option value="none">None</option></select></div>
          <div class="col-md-4"><label class="form-label">VNC bind</label><input name="vnc_bind" class="form-control" value="127.0.0.1"></div>
          <div class="col-md-4 d-flex align-items-end"><div class="form-check form-switch mb-2"><input name="autostart" class="form-check-input" type="checkbox" id="vmAuto"><label class="form-check-label" for="vmAuto">Start at host boot</label></div></div>
        </div></div>
        <div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center"><span>Cloud-init provisioning</span><div class="form-check form-switch mb-0"><input name="cloud_init_enabled" id="vmCloudInitEnabled" class="form-check-input" type="checkbox"><label class="form-check-label" for="vmCloudInitEnabled">Enable</label></div></div><div id="vmCloudInitFields" class="d-none"><div class="row g-3"><div class="col-md-6"><label class="form-label">Guest hostname</label><input name="cloud_init_hostname" id="vmCloudInitHostname" class="form-control mono" placeholder="Defaults to VM name"></div><div class="col-12"><label class="form-label">User-data</label><textarea name="cloud_init_user_data" id="vmCloudInitUserData" rows="10" class="form-control mono" spellcheck="false" placeholder="#cloud-config&#10;package_update: true&#10;runcmd:&#10;  - echo provisioned by LiteVMM > /etc/litevmm-provisioned"></textarea><div class="form-text">Paste <span class="mono">#cloud-config</span> YAML or a cloud-init shell script beginning with a shebang. The guest image must already contain cloud-init with NoCloud support.</div></div></div></div></div>
        <div class="form-section"><button class="btn btn-sm btn-outline-secondary" type="button" data-bs-toggle="collapse" data-bs-target="#vmAdvanced">Advanced options</button><div id="vmAdvanced" class="collapse mt-3"><div class="row g-3">
          <div class="col-md-4"><label class="form-label">Machine</label><select name="machine" class="form-select">${selectOptions(['q35','pc'], 'q35')}</select></div>
          <div class="col-md-4"><label class="form-label">CPU model</label><select name="cpu" class="form-select">${selectOptions(['host','max','kvm64','qemu64'], 'host')}</select></div>
          <div class="col-md-4"><label class="form-label">Boot order</label><select name="boot" class="form-select">${selectOptions(['c','d','dc','cd','n'], 'c')}</select></div>
          <div class="col-md-4"><label class="form-label">VNC display</label><input name="vnc_display" type="number" min="0" max="99" class="form-control" placeholder="auto"></div>
          <div class="col-12"><div class="form-check form-switch"><input name="emulation" id="vmAllowEmulation" class="form-check-input" type="checkbox"><label class="form-check-label" for="vmAllowEmulation">Allow software emulation when KVM is unavailable</label></div><div class="form-text">Lab-only fallback. It is much slower than nested KVM.</div></div>
        </div></div></div>
        <div class="form-section"><div class="form-section-title">Create command</div><pre id="vmCreatePreview" class="code-panel command-preview mb-0"></pre></div>
      </form>`, onSubmit: async (el,m) => {
        const f = new FormData($('#vmCreateForm', el)); const o = Object.fromEntries(f.entries()); o.autostart = f.has('autostart') ? 'true' : 'false'; o.emulation = f.has('emulation') ? 'true' : 'false'; o.cloud_init_enabled = f.has('cloud_init_enabled') ? 'true' : 'false';
        if (o.network !== 'bridge') delete o.bridge;
        if (o.network !== 'overlay') delete o.overlay;
        if (!['bridge','overlay'].includes(o.network)) delete o.vlan;
        if (o.cloud_init_enabled === 'true') {
          if (!(o.cloud_init_user_data || '').trim()) throw new Error('Cloud-init user-data is required when cloud-init is enabled.');
          if (!(o.cloud_init_hostname || '').trim()) o.cloud_init_hostname = o.name;
        } else { delete o.cloud_init_user_data; delete o.cloud_init_hostname; }
        delete o.cloud_init_enabled;
        await request('/vms', {method:'POST', form:o}); m.hide(); toast(`${o.name} created`); await renderRoute();
      }});
    const form = $('#vmCreateForm', $('#formModal'));
    const syncVmForm = () => {
      const fd = new FormData(form); const o = Object.fromEntries(fd.entries()); o.autostart = fd.has('autostart') ? 'true' : 'false'; o.cloud_init_enabled = fd.has('cloud_init_enabled') ? 'true' : 'false';
      const bridged = o.network === 'bridge';
      const overlay = o.network === 'overlay';
      $('#vmBridgeWrap', form).classList.toggle('d-none', !bridged);
      $('#vmBridge', form).disabled = !bridged;
      $('#vmOverlayWrap', form).classList.toggle('d-none', !overlay);
      $('#vmOverlay', form).disabled = !overlay;
      $('#vmVlanWrap', form).classList.toggle('d-none', !(bridged||overlay));
      form.vlan.disabled = !(bridged||overlay);
      const cloudInit = o.cloud_init_enabled === 'true';
      $('#vmCloudInitFields', form).classList.toggle('d-none', !cloudInit);
      form.cloud_init_hostname.disabled = !cloudInit;
      form.cloud_init_user_data.disabled = !cloudInit;
      if (cloudInit && !form.cloud_init_hostname.value.trim() && form.name.value.trim()) form.cloud_init_hostname.placeholder = form.name.value.trim();
      setPreview('#vmCreatePreview', vmCreateCommand(o));
    };
    form.addEventListener('input', syncVmForm); form.addEventListener('change', syncVmForm); syncVmForm();
  }

  async function openVMDetails(name) {
    const [vm, images, nets, consoleInfo, metrics, cloudInit] = await Promise.all([
      request(`/vms/${encodeURIComponent(name)}`), request('/images'), request('/networks'), request(`/vms/${encodeURIComponent(name)}/console`).catch(()=>null), request(`/vms/${encodeURIComponent(name)}/metrics`).catch(()=>null), request(`/vms/${encodeURIComponent(name)}/cloud-init`).catch(()=>({enabled:false,instance_id:'',local_hostname:'',user_data:''}))
    ]);
    const c = vm.config || {};
    const disks = indexedConfig(c, 'DISK', ['FILE','FORMAT','BUS']);
    const nics = indexedConfig(c, 'NIC', ['MODE','MODEL','MAC','BRIDGE','VLAN']);
    const pci = indexedConfig(c, 'PCI', ['BDF']);
    const imgOpts = [`<option value="">None</option>`, ...images.map(i=>`<option ${i.name===c.ISO?'selected':''} value="${esc(i.name)}">${esc(i.name)}</option>`)].join('');
    const bridgeOpts = (nets.bridges || []).map(b=>`<option value="${esc(b)}">${esc(b)}</option>`).join('');
    modal({eyebrow:`QEMU / KVM · ${vm.state}`, title:name, submitText:'Save settings', body:`
      <form id="vmEditForm">
        <div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center"><span>Resource usage</span><span class="fw-normal text-lowercase">5 second refresh</span></div>${meterRow('vmmetric',[{key:'cpu',label:'CPU'},{key:'memory',label:'Memory'},{key:'disk',label:'Disk allocation'},{key:'network',label:'Network',progress:false}])}<div class="form-text mt-2">VM memory is the host RSS of the QEMU process. Disk is host image allocation versus virtual capacity, not guest filesystem fullness.</div></div>
        <div class="form-section"><div class="form-section-title">Hardware</div><div class="row g-3">
          <div class="col-md-3"><label class="form-label">vCPUs</label><select name="cpus" class="form-select">${selectOptions(Array.from({length:16},(_,i)=>String(i+1)), c.VCPUS)}</select></div>
          <div class="col-md-3"><label class="form-label">Memory MB</label><select name="memory" class="form-select">${selectOptions(['256','512','1024','2048','4096','8192','16384'], c.MEMORY_MB)}</select></div>
          <div class="col-md-3"><label class="form-label">CPU model</label><select name="cpu" class="form-select">${selectOptions(['host','max','kvm64','qemu64'], c.CPU || 'host')}</select></div>
          <div class="col-md-3"><label class="form-label">Machine</label><select name="machine" class="form-select">${selectOptions(['q35','pc'], c.MACHINE || 'q35')}</select></div>
          <div class="col-md-4"><label class="form-label">ISO</label><select name="iso" class="form-select">${imgOpts}</select></div>
          <div class="col-md-3"><label class="form-label">Boot order</label><select name="boot" class="form-select">${selectOptions(['c','d','dc','cd','n'], c.BOOT_ORDER || 'c')}</select></div>
          <div class="col-md-3"><label class="form-label">Display</label><select name="display" class="form-select"><option value="vnc" ${c.DISPLAY==='vnc'?'selected':''}>VNC</option><option value="none" ${c.DISPLAY==='none'?'selected':''}>None</option></select></div>
          <div class="col-md-2 d-flex align-items-end"><div class="form-check form-switch mb-2"><input name="autostart" id="editAuto" class="form-check-input" type="checkbox" ${String(c.AUTOSTART)==='true'?'checked':''}><label class="form-check-label" for="editAuto">Autostart</label></div></div>
          <div class="col-12"><div class="form-check form-switch"><input name="emulation" id="editEmulation" class="form-check-input" type="checkbox" ${String(c.ALLOW_TCG)==='true'?'checked':''}><label class="form-check-label" for="editEmulation">Allow software emulation when KVM is unavailable</label></div></div>
        </div>${vm.state === 'running' ? '<div class="alert alert-warning small mt-3 mb-0">Hardware settings can only be changed while the VM is stopped.</div>' : ''}</div>
        <div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center"><span>Cloud-init provisioning</span><div class="form-check form-switch mb-0"><input name="cloud_init_enabled" id="editCloudInitEnabled" class="form-check-input" type="checkbox" ${cloudInit.enabled?'checked':''} ${vm.state==='running'?'disabled':''}><label class="form-check-label" for="editCloudInitEnabled">Enabled</label></div></div><div id="editCloudInitFields" class="${cloudInit.enabled?'':'d-none'}"><div class="row g-3"><div class="col-md-6"><label class="form-label">Guest hostname</label><input name="cloud_init_hostname" class="form-control mono" value="${esc(cloudInit.local_hostname||name)}" ${vm.state==='running'?'disabled':''}></div><div class="col-md-6"><label class="form-label">Instance ID</label><input class="form-control mono" value="${esc(cloudInit.instance_id||'Generated when saved')}" readonly><div class="form-text">Changing cloud-init content generates a new instance ID for the next boot.</div></div><div class="col-12"><label class="form-label">User-data</label><textarea name="cloud_init_user_data" rows="10" class="form-control mono" spellcheck="false" ${vm.state==='running'?'disabled':''}>${esc(cloudInit.user_data||'')}</textarea><div class="form-text">The seed is attached as a NoCloud <span class="mono">cidata</span> ISO. The guest image must include cloud-init.</div></div></div></div>${vm.state==='running'?'<div class="alert alert-warning small mt-3 mb-0">Stop the VM before changing cloud-init. The current seed remains attached while it is running.</div>':''}</div>
        <div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center">Disks <button type="button" class="btn btn-sm btn-outline-primary" id="addDiskBtn">Add disk</button></div>${resourceList(disks, d=>`<strong>disk${d.index}</strong> · ${esc(d.FILE || '')} · ${esc(d.FORMAT || '')} · ${esc(d.BUS || '')}`, 'disk')}</div>
        <div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center">Network adapters <button type="button" class="btn btn-sm btn-outline-primary" id="addNicBtn">Add NIC</button></div>${resourceList(nics, n=>`<strong>nic${n.index}</strong> · ${esc(n.MODE || '')}${n.BRIDGE ? ` / ${esc(n.BRIDGE)}`:''} · ${esc(n.MODEL || '')}${n.VLAN ? ` · VLAN ${esc(n.VLAN)}` : ''} · <span class="mono">${esc(n.MAC || '')}</span>`, 'nic')}</div>
        <div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center">PCI passthrough <button type="button" class="btn btn-sm btn-outline-primary" id="addPciBtn">Add device</button></div>${resourceList(pci, p=>`<strong>pci${p.index}</strong> · <span class="mono">${esc(p.BDF || '')}</span>`, 'pci')}</div>
        <div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center">Console ${vm.state === 'running' && c.DISPLAY === 'vnc' ? `<button type="button" class="btn btn-sm btn-outline-primary" id="openConsoleBtn">Open noVNC</button>` : ''}</div>${consoleInfo ? `<div class="row g-2 small"><div class="col-md-6"><div class="border rounded-3 p-3"><div class="text-secondary">VNC</div><div class="mono mt-1">${esc(consoleInfo.vnc_host || consoleInfo.vnc_bind || '')}${consoleInfo.vnc_port ? ':'+esc(consoleInfo.vnc_port) : ''}</div></div></div><div class="col-md-6"><div class="border rounded-3 p-3"><div class="text-secondary">Serial / QMP</div><div class="mono mt-1 text-break">${esc(consoleInfo.serial_socket || consoleInfo.qmp_socket || '')}</div></div></div></div>` : '<div class="text-secondary small">Console information unavailable.</div>'}</div>
      </form>`, onSubmit: async (el,m) => {
        const f = new FormData($('#vmEditForm',el)); const updates = {cpus:f.get('cpus'),memory:f.get('memory'),cpu:f.get('cpu'),machine:f.get('machine'),emulation:f.has('emulation')?'true':'false',iso:f.get('iso') || '',boot:f.get('boot'),display:f.get('display'),autostart:f.has('autostart')?'true':'false'};
        for (const [field,value] of Object.entries(updates)) await request(`/vms/${encodeURIComponent(name)}`, {method:'PATCH', form:{field,value}});
        if (vm.state !== 'running') {
          const enabled = f.has('cloud_init_enabled');
          const userData = f.get('cloud_init_user_data') || ''; const hostname = f.get('cloud_init_hostname') || name;
          if (enabled) {
            if (!userData.trim()) throw new Error('Cloud-init user-data is required when cloud-init is enabled.');
            if (!cloudInit.enabled || userData !== (cloudInit.user_data||'') || hostname !== (cloudInit.local_hostname||name)) await request(`/vms/${encodeURIComponent(name)}/cloud-init`, {method:'PUT', form:{user_data:userData,hostname}});
          } else if (cloudInit.enabled) await request(`/vms/${encodeURIComponent(name)}/cloud-init`, {method:'DELETE'});
        }
        m.hide(); toast(`${name} updated`); await renderRoute();
      }});

    const editCloudToggle = $('#editCloudInitEnabled', $('#formModal'));
    if (editCloudToggle && vm.state !== 'running') editCloudToggle.onchange=()=>{$('#editCloudInitFields', $('#formModal')).classList.toggle('d-none',!editCloudToggle.checked);};
    if (metrics) renderVMMetrics(metrics, name);
    startDetailMetrics(`/vms/${encodeURIComponent(name)}/metrics`, m=>renderVMMetrics(m,name));

    $$('[data-remove-disk]', $('#formModal')).forEach(b=>b.onclick=()=>confirmAction('Remove disk', `Remove disk ${b.dataset.removeDisk} from ${name}?`, async()=>{await request(`/vms/${encodeURIComponent(name)}/disks/${b.dataset.removeDisk}?delete_file=true`,{method:'DELETE'}); bootstrap.Modal.getInstance($('#formModal'))?.hide(); await openVMDetails(name);}));
    $$('[data-remove-nic]', $('#formModal')).forEach(b=>b.onclick=()=>confirmAction('Remove NIC', `Remove NIC ${b.dataset.removeNic} from ${name}?`, async()=>{await request(`/vms/${encodeURIComponent(name)}/nics/${b.dataset.removeNic}`,{method:'DELETE'}); bootstrap.Modal.getInstance($('#formModal'))?.hide(); await openVMDetails(name);}));
    $$('[data-edit-nic]', $('#formModal')).forEach(b=>b.onclick=()=>subModalEditNic(name, nics.find(n=>String(n.index)===b.dataset.editNic), bridgeOpts));
    $$('[data-remove-pci]', $('#formModal')).forEach(b=>b.onclick=()=>confirmAction('Remove PCI device', `Remove PCI entry ${b.dataset.removePci}?`, async()=>{await request(`/vms/${encodeURIComponent(name)}/pci/${b.dataset.removePci}`,{method:'DELETE'}); bootstrap.Modal.getInstance($('#formModal'))?.hide(); await openVMDetails(name);}));
    $('#addDiskBtn').onclick=()=>subModalAddDisk(name);
    $('#addNicBtn').onclick=()=>subModalAddNic(name, bridgeOpts);
    $('#addPciBtn').onclick=()=>subModalAddPci(name);
    const consoleBtn = $('#openConsoleBtn'); if (consoleBtn) consoleBtn.onclick=()=>openConsole(name);
  }

  function indexedConfig(c, prefix, fields) {
    const ids = new Set(); Object.keys(c).forEach(k=>{ const m=k.match(new RegExp(`^${prefix}_(\\d+)_`)); if(m) ids.add(Number(m[1])); });
    return [...ids].sort((a,b)=>a-b).map(index=>{ const o={index}; fields.forEach(f=>o[f]=c[`${prefix}_${index}_${f}`] || ''); return o; });
  }
  function selectOptions(values, current) {
    const options = [...new Set([...values, String(current || '')].filter(Boolean))];
    return options.map(value => `<option value="${esc(value)}" ${String(value) === String(current) ? 'selected' : ''}>${esc(value)}</option>`).join('');
  }
  function resourceList(items, label, kind) {
    if(!items.length) return '<div class="text-secondary small">None configured.</div>';
    return `<div class="list-group list-group-flush list-compact">${items.map(x=>`<div class="list-group-item px-0 d-flex align-items-center gap-2"><div class="small flex-grow-1">${label(x)}</div>${kind === 'nic' ? `<button type="button" class="btn btn-sm btn-outline-secondary" data-edit-nic="${x.index}">Edit</button>` : ''}<button type="button" class="btn btn-sm btn-outline-danger" data-remove-${kind}="${x.index}">Remove</button></div>`).join('')}</div>`;
  }
  function nicModelOptions(current) {
    return selectOptions(['virtio-net-pci','e1000e','e1000','rtl8139'], current);
  }
  function subModalAddDisk(name){
    modal({eyebrow:name,title:'Add virtual disk',submitText:'Add disk',size:'sm',body:`<form id="subForm"><label class="form-label">Size</label><input name="size" value="20G" class="form-control mb-3"><label class="form-label">Format</label><select name="format" class="form-select mb-3"><option>qcow2</option><option>raw</option></select><label class="form-label">Bus</label><select name="bus" class="form-select"><option>virtio</option><option>sata</option><option>scsi</option></select></form>`,onSubmit:async(el,m)=>{const f=Object.fromEntries(new FormData($('#subForm',el)).entries());await request(`/vms/${encodeURIComponent(name)}/disks`,{method:'POST',form:f});m.hide();await openVMDetails(name);}});
  }
  function subModalAddNic(name, bridgeOpts){
    modal({eyebrow:name,title:'Add network adapter',submitText:'Add NIC',size:'sm',body:`<form id="subForm"><label class="form-label">Mode</label><select name="mode" id="nicAddMode" class="form-select mb-3"><option value="nat">NAT</option><option value="bridge">Bridge</option></select><div id="nicAddBridgeWrap"><label class="form-label">Bridge</label><select name="bridge" class="form-select mb-3"><option value="">None</option>${bridgeOpts}</select><label class="form-label">VLAN ID</label><input name="vlan" type="number" min="1" max="4094" class="form-control mb-3" placeholder="Untagged"><div class="form-text mb-3">Optional 802.1Q access VLAN. The physical bridge uplink must carry this VLAN.</div></div><label class="form-label">Model</label><select name="model" class="form-select"><option>virtio-net-pci</option><option>e1000e</option><option>e1000</option><option>rtl8139</option></select></form>`,onSubmit:async(el,m)=>{const f=Object.fromEntries(new FormData($('#subForm',el)).entries());if(f.mode!=='bridge'){delete f.bridge;delete f.vlan;}await request(`/vms/${encodeURIComponent(name)}/nics`,{method:'POST',form:f});m.hide();await openVMDetails(name);}});
    const form = $('#subForm', $('#formModal'));
    const syncNicAddForm = () => {
      $('#nicAddBridgeWrap', form).classList.toggle('d-none', form.mode.value !== 'bridge');
    };
    form.addEventListener('change', syncNicAddForm); syncNicAddForm();
  }
  function subModalEditNic(name, nic, bridgeOpts){
    modal({eyebrow:name,title:`Edit NIC ${nic.index}`,submitText:'Save NIC',size:'sm',body:`<form id="subForm"><label class="form-label">Mode</label><select name="mode" id="nicEditMode" class="form-select mb-3"><option value="nat" ${nic.MODE==='nat'?'selected':''}>NAT</option><option value="bridge" ${nic.MODE==='bridge'?'selected':''}>Bridge</option></select><div id="nicEditBridgeWrap"><label class="form-label">Bridge</label><select name="bridge" class="form-select mb-3"><option value="">None</option>${bridgeOpts.replace(`value="${esc(nic.BRIDGE)}"`, `value="${esc(nic.BRIDGE)}" selected`)}</select><label class="form-label mt-3">VLAN ID</label><input name="vlan" type="number" min="1" max="4094" class="form-control mb-2" value="${esc(nic.VLAN||'')}" placeholder="Untagged"><div class="form-text mb-3">Optional 802.1Q access VLAN.</div></div><label class="form-label">Model</label><select name="model" class="form-select mb-3">${nicModelOptions(nic.MODEL)}</select><label class="form-label">MAC address</label><input class="form-control mono" value="${esc(nic.MAC)}" readonly></form>`,onSubmit:async(el,m)=>{const f=Object.fromEntries(new FormData($('#subForm',el)).entries());for(const [field,value] of Object.entries(f)){if((field==='bridge'||field==='vlan')&&f.mode!=='bridge')continue;await request(`/vms/${encodeURIComponent(name)}/nics/${nic.index}`,{method:'PATCH',form:{field,value}});}m.hide();toast(`${name}: NIC ${nic.index} updated`);await openVMDetails(name);}});
    const form = $('#subForm', $('#formModal'));
    const syncNicEditForm = () => {
      $('#nicEditBridgeWrap', form).classList.toggle('d-none', form.mode.value !== 'bridge');
    };
    form.addEventListener('change', syncNicEditForm); syncNicEditForm();
  }
  function subModalAddPci(name){
    modal({eyebrow:name,title:'Add PCI passthrough',submitText:'Add device',size:'sm',body:`<form id="subForm"><label class="form-label">PCI BDF</label><input name="bdf" class="form-control mono" placeholder="01:00.0"><div class="form-text">Host VFIO/IOMMU setup must already be complete.</div></form>`,onSubmit:async(el,m)=>{const f=Object.fromEntries(new FormData($('#subForm',el)).entries());await request(`/vms/${encodeURIComponent(name)}/pci`,{method:'POST',form:f});m.hide();await openVMDetails(name);}});
  }

  async function loadContainers() {
    const containers = await request('/docker/containers'); state.cache.containers=containers;
    const rows = containers.map(c=>{const labels=c.Labels||{};const project=labels['com.docker.compose.project'] || labels['com.docker.compose.project.name'] || '';const service=labels['com.docker.compose.service'] || '';return `<tr><td><div class="resource-name">${esc(c.Names || c.Name || '')}</div><div class="small text-secondary mono">${esc(c.ID || '')}</div>${project?`<div class="small text-primary">Compose: ${esc(project)}${service?` / ${esc(service)}`:''}</div>`:''}</td><td>${stateBadge(c.State || '')}</td><td class="mono small">${esc(c.Image || '')}</td><td class="small text-secondary">${esc(c.Status || '')}</td><td><div class="action-row">
      <button class="btn btn-sm btn-outline-secondary" data-ctr-details="${esc(c.Names || c.Name || '')}">Inspect</button>
      <button class="btn btn-sm btn-outline-secondary" data-ctr-logs="${esc(c.Names || c.Name || '')}">Logs</button>
      <button class="btn btn-sm btn-outline-secondary" data-ctr-commit="${esc(c.Names || c.Name || '')}">Snapshot</button>
      ${String(c.State||'').toLowerCase()==='running'?`<button class="btn btn-sm btn-outline-warning" data-ctr-stop="${esc(c.Names || '')}">Stop</button><button class="btn btn-sm btn-outline-secondary" data-ctr-restart="${esc(c.Names || '')}">Restart</button>`:`<button class="btn btn-sm btn-outline-success" data-ctr-start="${esc(c.Names || '')}">Start</button>`}
      ${String(c.State||'').toLowerCase()==='running'?`<button class="btn btn-sm btn-outline-primary" data-ctr-terminal="${esc(c.Names || '')}">Terminal</button>`:''}
      <button class="btn btn-sm btn-outline-danger" data-ctr-delete="${esc(c.Names || '')}">Delete</button>
    </div></td></tr>`;});
    $('#view').innerHTML=card('Containers',table(['Name','State','Image','Status',''],rows,'No Docker containers exist.'),`<button class="btn btn-sm btn-outline-secondary me-2" id="containerImagesBtn">Image library</button><button class="btn btn-sm btn-primary" id="createCtrBtn">Create container</button><button class="btn btn-sm btn-outline-primary ms-2" id="deployComposeBtn">Deploy Compose</button>`);
    $('#createCtrBtn').onclick=openCreateContainer;
    $('#containerImagesBtn').onclick=openDockerImageLibrary;
    $('#deployComposeBtn').onclick=openComposeProject;
    $$('[data-ctr-start]').forEach(b=>b.onclick=()=>containerAction(b.dataset.ctrStart,'start',b));
    $$('[data-ctr-stop]').forEach(b=>b.onclick=()=>containerAction(b.dataset.ctrStop,'stop',b));
    $$('[data-ctr-restart]').forEach(b=>b.onclick=()=>containerAction(b.dataset.ctrRestart,'restart',b));
    $$('[data-ctr-logs]').forEach(b=>b.onclick=()=>openContainerLogs(b.dataset.ctrLogs));
    $$('[data-ctr-terminal]').forEach(b=>b.onclick=()=>openContainerTerminal(b.dataset.ctrTerminal));
    $$('[data-ctr-commit]').forEach(b=>b.onclick=()=>openCommitContainer(b.dataset.ctrCommit));
    $$('[data-ctr-delete]').forEach(b=>b.onclick=()=>confirmAction('Delete container',`Delete ${b.dataset.ctrDelete}?`,async()=>{await request(`/docker/containers/${encodeURIComponent(b.dataset.ctrDelete)}?force=true`,{method:'DELETE'});await renderRoute();}));
    $$('[data-ctr-details]').forEach(b=>b.onclick=()=>openContainerDetails(b.dataset.ctrDetails));
  }
  async function containerAction(name, action, button){const verb=action==='start'?'Starting':action==='stop'?'Stopping':'Restarting';const unlock=lockActionItem(button,verb);toast(`${name}: ${verb.toLowerCase()}...`,'Container action in progress');try{await request(`/docker/containers/${encodeURIComponent(name)}/${action}`,{method:'POST'});toast(`${name}: ${verb.toLowerCase()} complete`);await renderRoute();}catch(e){unlock();toast(e.message,'Container action failed');await renderRoute();}}

  async function loadCompose() {
    const projects = await request('/compose/projects');
    const rows = projects.map(project=>`<tr><td class="mono">${esc(project.name)}</td><td>${esc(project.running)} running</td><td><div class="action-row"><button class="btn btn-sm btn-outline-secondary" data-compose-view="${esc(project.name)}">View</button><button class="btn btn-sm btn-outline-primary" data-compose-deploy="${esc(project.name)}">Deploy</button><button class="btn btn-sm btn-outline-warning" data-compose-down="${esc(project.name)}">Stop</button><button class="btn btn-sm btn-outline-danger" data-compose-delete="${esc(project.name)}">Delete</button></div></td></tr>`);
    $('#view').innerHTML=card('Compose projects',table(['Project','Status',''],rows,'No Compose projects stored.'),'<button class="btn btn-sm btn-primary" id="composeNewBtn">Deploy Compose</button>');
    $('#composeNewBtn').onclick=openComposeProject;
    $$('[data-compose-view]').forEach(button=>button.onclick=()=>viewComposeProject(button.dataset.composeView));
    $$('[data-compose-deploy]').forEach(button=>button.onclick=()=>composeAction(button,'Deploying',`/compose/projects/${encodeURIComponent(button.dataset.composeDeploy)}/deploy`));
    $$('[data-compose-down]').forEach(button=>button.onclick=()=>composeAction(button,'Stopping',`/compose/projects/${encodeURIComponent(button.dataset.composeDown)}/down`));
    $$('[data-compose-delete]').forEach(button=>button.onclick=()=>confirmAction('Delete Compose project',`Stop and delete ${button.dataset.composeDelete}?`,async()=>{await request(`/compose/projects/${encodeURIComponent(button.dataset.composeDelete)}`,{method:'DELETE'});await loadCompose();}));
  }

  async function composeAction(button, label, path) {
    const unlock=lockActionItem(button,label);
    try { await request(path,{method:'POST',form:{}}); toast(`${label.toLowerCase()} complete`); await loadCompose(); }
    catch(error) { unlock(); toast(error.message,'Compose action failed'); }
  }

  async function viewComposeProject(name) {
    const yaml=await request(`/compose/projects/${encodeURIComponent(name)}`);
    modal({eyebrow:'Docker Compose',title:name,body:`<textarea class="form-control mono" rows="18" readonly>${esc(yaml)}</textarea>`});
  }

  function openComposeProject() {
    modal({eyebrow:'Docker Compose',title:'Deploy Compose project',submitText:'Deploy',body:`<form id="composeForm"><div class="row g-3"><div class="col-md-5"><label class="form-label">Project name</label><input name="name" class="form-control mono" placeholder="web-stack" required></div><div class="col-md-7"><label class="form-label">Compose file</label><input id="composeFile" type="file" accept=".yaml,.yml,text/yaml,application/yaml" class="form-control"></div><div class="col-12"><label class="form-label">Compose YAML</label><textarea name="yaml" id="composeYaml" class="form-control mono" rows="18" placeholder="services:\n  app:\n    image: nginx:latest\n    ports:\n      - 8080:80" required></textarea></div></div></form>`,onSubmit:async(el,m)=>{const form=$('#composeForm',el);const name=new FormData(form).get('name');const yaml=new FormData(form).get('yaml');await request(`/compose/projects/${encodeURIComponent(name)}`,{method:'PUT',body:yaml,headers:{'Content-Type':'application/x-yaml'}});await request(`/compose/projects/${encodeURIComponent(name)}/deploy`,{method:'POST',form:{}});m.hide();toast(`${name}: deployed`);location.hash='#containers';await renderRoute();}});
    $('#composeFile', $('#formModal')).onchange=async event=>{const file=event.target.files[0];if(file)$('#composeYaml', $('#formModal')).value=await file.text();};
  }

  async function fetchContainerLogs(name, {follow=false, tail=300, target=null, signal=null} = {}) {
    const params = new URLSearchParams({ tail: String(tail) });
    if (follow) params.set('follow', 'true');
    const res = await fetch(`${API}/docker/containers/${encodeURIComponent(name)}/logs?${params}`, { credentials:'same-origin', headers:{'Accept':'text/plain'}, signal });
    if (!res.ok) throw new Error(await res.text() || `${res.status} ${res.statusText}`);
    if (!follow || !res.body || !target) return res.text();
    const reader = res.body.getReader(); const decoder = new TextDecoder();
    while (true) {
      const {value, done} = await reader.read();
      if (done) break;
      target.textContent += decoder.decode(value, {stream:true});
      target.scrollTop = target.scrollHeight;
    }
    target.textContent += decoder.decode();
  }

  async function openContainerLogs(name) {
    let controller = null;
    modal({eyebrow:'Docker logs',title:name,submitText:'Stream logs',body:`<div class="d-flex align-items-center gap-2 mb-3"><label class="form-label mb-0">Tail</label><input id="logTail" type="number" min="1" value="300" class="form-control form-control-sm" style="max-width:7rem"><button id="refreshLogsBtn" class="btn btn-sm btn-outline-secondary" type="button">Refresh</button><button id="stopLogsBtn" class="btn btn-sm btn-outline-danger" type="button" disabled>Stop stream</button></div><pre id="containerLogs" class="code-panel log-panel mb-0">Loading logs...</pre>`,onSubmit:async(el)=>{
      const out=$('#containerLogs',el); const tail=$('#logTail',el).value || 300; controller?.abort(); controller=new AbortController(); out.textContent=''; $('#stopLogsBtn',el).disabled=false;
      try { await fetchContainerLogs(name,{follow:true,tail,target:out,signal:controller.signal}); } catch(e) { if(e.name!=='AbortError') toast(e.message,'Log stream failed'); } finally { $('#stopLogsBtn',el).disabled=true; }
    }});
    const el=$('#formModal'), out=$('#containerLogs',el);
    const load=async()=>{try{out.textContent=await fetchContainerLogs(name,{tail:$('#logTail',el).value || 300}); out.scrollTop=out.scrollHeight;}catch(e){out.textContent=e.message;}};
    $('#refreshLogsBtn',el).onclick=load;
    $('#stopLogsBtn',el).onclick=()=>controller?.abort();
    el.addEventListener('hidden.bs.modal',()=>controller?.abort(),{once:true});
    await load();
  }

  async function openContainerTerminal(name) {
    modal({eyebrow:'Docker exec',title:`Terminal: ${name}`,submitText:'Open terminal',size:'sm',body:`<form id="terminalForm"><label class="form-label">Command</label><input name="shell" class="form-control mono" value="/bin/sh"><div class="form-text">Use a shell or executable available inside the container.</div></form>`,onSubmit:async(el,m)=>{
      const shell = new FormData($('#terminalForm',el)).get('shell') || '/bin/sh';
      const session = await request(`/docker/containers/${encodeURIComponent(name)}/exec/session`, {method:'POST', form:{shell}});
      m.hide();
      window.open(session.url, `vmapi-docker-terminal-${name}`, 'noopener');
      toast(`${name}: terminal opened`);
    }});
  }

  function openCommitContainer(name) {
    modal({eyebrow:'Docker snapshot',title:`Snapshot ${name}`,submitText:'Create image',body:`<form id="commitForm"><label class="form-label">Image tag</label><input name="image" class="form-control mono mb-3" placeholder="local/${esc(name)}:snapshot" required><label class="form-label">Message</label><input name="message" class="form-control mb-3" placeholder="Snapshot from LiteVMM"><div class="form-check form-switch"><input name="pause" id="commitPause" class="form-check-input" type="checkbox" checked><label class="form-check-label" for="commitPause">Pause container while committing</label></div></form>`,onSubmit:async(el,m)=>{const fd=new FormData($('#commitForm',el));const image=fd.get('image');await request(`/docker/containers/${encodeURIComponent(name)}/commit`,{method:'POST',form:{image,message:fd.get('message'),pause:fd.has('pause')?'true':'false'}});m.hide();toast(`${image} created`);await renderRoute();}});
  }

  async function openCreateContainer(){
    const [images,nets,vols]=await Promise.all([request('/docker/images'),request('/docker/networks'),request('/docker/volumes')]);
    const imageNames=[...new Set(images.flatMap(i=>[i.Repository && i.Tag && i.Tag!=='<none>'?`${i.Repository}:${i.Tag}`:null,i.Tag && i.Repository?null:i.Name]).filter(Boolean))];
    const imageList=imageNames.map(n=>`<option value="${esc(n)}"></option>`).join('');
    const netOpts=[`<option value="">Default</option>`,...nets.map(n=>`<option value="${esc(n.Name||n.name||'')}">${esc(n.Name||n.name||'')}</option>`)].join('');
    const volNote=vols.length?`Available named volumes: ${vols.map(v=>esc(v.Name||v.name||'')).join(', ')}`:'No named volumes yet.';
    modal({eyebrow:'Docker daemon',title:'Create container',submitText:'Create container',body:`<form id="ctrCreateForm">
      <div class="form-section"><div class="form-section-title">Identity</div><div class="row g-3"><div class="col-md-5"><label class="form-label">Name</label><input name="name" class="form-control" required></div><div class="col-md-7"><label class="form-label">Image</label><input name="image" list="dockerImageList" class="form-control" placeholder="nginx:latest" required><datalist id="dockerImageList">${imageList}</datalist></div></div></div>
      <div class="form-section"><div class="form-section-title">Resources and lifecycle</div><div class="row g-3"><div class="col-md-3"><label class="form-label">CPUs</label><input name="cpus" class="form-control" placeholder="2"></div><div class="col-md-3"><label class="form-label">Memory</label><input name="memory" class="form-control" placeholder="512m"></div><div class="col-md-3"><label class="form-label">Restart</label><select name="restart" class="form-select"><option value="">Default</option><option>no</option><option>unless-stopped</option><option>always</option><option>on-failure</option></select></div><div class="col-md-3"><label class="form-label">Network</label><select name="network" id="ctrNetMode" class="form-select">${netOpts}</select></div><div class="col-12"><div class="form-check form-switch"><input name="start_at_boot" id="ctrStartAtBoot" class="form-check-input" type="checkbox"><label class="form-check-label" for="ctrStartAtBoot">Start at host boot</label></div><div class="form-text">Uses Docker's <span class="mono">unless-stopped</span> restart policy.</div></div></div></div>
      <div class="form-section"><div class="form-section-title">Runtime options</div><div class="row g-3"><div class="col-md-6"><label class="form-label">Environment <span class="text-secondary">one per line</span></label><textarea name="env" rows="4" class="form-control mono" placeholder="MODE=production"></textarea></div><div class="col-md-6"><label class="form-label">Published ports <span class="text-secondary">one per line</span></label><textarea name="publish" rows="4" class="form-control mono" placeholder="8080:80"></textarea></div><div class="col-md-6"><label class="form-label">Volumes / bind mounts</label><textarea name="volume" rows="4" class="form-control mono" placeholder="appdata:/data"></textarea><div class="form-text">${volNote}</div></div><div class="col-md-6"><label class="form-label">Labels</label><textarea name="label" rows="4" class="form-control mono" placeholder="role=frontend"></textarea></div><div class="col-12"><label class="form-label">Command arguments <span class="text-secondary">one argument per line</span></label><textarea name="cmd" rows="3" class="form-control mono" placeholder="sleep&#10;3600"></textarea></div><div class="col-md-4"><label class="form-label">Hostname</label><input name="hostname" class="form-control"></div><div class="col-md-4"><label class="form-label">User</label><input name="user" class="form-control"></div><div class="col-md-4"><label class="form-label">Working directory</label><input name="workdir" class="form-control"></div><div class="col-md-6"><label class="form-label">Entrypoint</label><input name="entrypoint" class="form-control"></div><div class="col-md-6 d-flex align-items-end"><div class="form-check form-switch mb-2"><input name="read_only" id="ctrRO" class="form-check-input" type="checkbox"><label class="form-check-label" for="ctrRO">Read-only root filesystem</label></div></div></div></div>
      <div class="form-section"><div class="form-section-title">Create command</div><pre id="ctrCreatePreview" class="code-panel command-preview mb-0"></pre></div>
    </form>`,onSubmit:async(el,m)=>{const fd=new FormData($('#ctrCreateForm',el));const o={name:fd.get('name'),image:fd.get('image'),cpus:fd.get('cpus'),memory:fd.get('memory'),restart:fd.has('start_at_boot')?'unless-stopped':fd.get('restart'),network:fd.get('network'),hostname:fd.get('hostname'),user:fd.get('user'),workdir:fd.get('workdir'),entrypoint:fd.get('entrypoint'),read_only:fd.has('read_only')?'true':'false',env:lines(fd.get('env')),publish:lines(fd.get('publish')),volume:lines(fd.get('volume')),label:lines(fd.get('label')),cmd:lines(fd.get('cmd'))};await request('/docker/containers',{method:'POST',form:o});m.hide();toast(`${o.name} created`);await renderRoute();}});
    const form = $('#ctrCreateForm', $('#formModal'));
    const syncCtrForm = () => {
      const fd = new FormData(form);
      setPreview('#ctrCreatePreview', containerCreateCommand({name:fd.get('name'),image:fd.get('image'),cpus:fd.get('cpus'),memory:fd.get('memory'),restart:fd.get('restart'),network:fd.get('network'),hostname:fd.get('hostname'),user:fd.get('user'),workdir:fd.get('workdir'),entrypoint:fd.get('entrypoint'),read_only:fd.has('read_only')?'true':'false',env:lines(fd.get('env')),publish:lines(fd.get('publish')),volume:lines(fd.get('volume')),label:lines(fd.get('label')),cmd:lines(fd.get('cmd'))}));
    };
    form.addEventListener('input', syncCtrForm); form.addEventListener('change', syncCtrForm); syncCtrForm();
  }

  async function openContainerDetails(name){
    const [data,metrics]=await Promise.all([
      request(`/docker/containers/${encodeURIComponent(name)}`),
      request(`/docker/containers/${encodeURIComponent(name)}/metrics`).catch(()=>null)
    ]);
    const d=first(data)||{}; const hc=d.HostConfig||{}; const cfg=d.Config||{}; const st=d.State||{};
    modal({eyebrow:`Docker · ${st.Status || ''}`,title:name,submitText:'Update resources',body:`<form id="ctrEditForm">
      <div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center"><span>Resource usage</span><span class="fw-normal text-lowercase">5 second refresh</span></div>${meterRow('ctrmetric',[{key:'cpu',label:'CPU'},{key:'memory',label:'Memory'},{key:'disk',label:'Writable layer',progress:false},{key:'network',label:'Network',progress:false}])}<div class="form-text mt-2">Docker disk usage is the writable layer size. There is no fixed virtual-disk capacity unless storage quotas are configured outside this layer.</div></div>
      <div class="form-section"><div class="form-section-title">Runtime resources</div><div class="row g-3"><div class="col-md-4"><label class="form-label">CPUs</label><input name="cpus" class="form-control" placeholder="2"></div><div class="col-md-4"><label class="form-label">Memory</label><input name="memory" class="form-control" placeholder="512m"></div><div class="col-md-4"><label class="form-label">Restart policy</label><select name="restart" class="form-select"><option value="">No change</option><option>no</option><option>unless-stopped</option><option>always</option><option>on-failure</option></select></div></div></div>
      <div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center"><span>Summary</span><span class="action-row"><button type="button" class="btn btn-sm btn-outline-secondary" id="detailsLogsBtn">Logs</button><button type="button" class="btn btn-sm btn-outline-secondary" id="detailsCommitBtn">Snapshot</button>${st.Status==='running'?'<button type="button" class="btn btn-sm btn-outline-primary" id="detailsTerminalBtn">Terminal</button>':''}</span></div><dl class="row small mb-0"><dt class="col-4 text-secondary">Image</dt><dd class="col-8 mono text-break">${esc(cfg.Image||'')}</dd><dt class="col-4 text-secondary">Status</dt><dd class="col-8">${esc(st.Status||'')}</dd><dt class="col-4 text-secondary">Restart</dt><dd class="col-8">${esc(hc.RestartPolicy?.Name||'')}</dd><dt class="col-4 text-secondary">Network mode</dt><dd class="col-8">${esc(hc.NetworkMode||'')}</dd></dl></div>
      <div class="form-section"><div class="form-section-title">Docker inspect</div><pre class="code-panel mb-0">${esc(JSON.stringify(d,null,2))}</pre></div></form>`,onSubmit:async(el,m)=>{const fd=new FormData($('#ctrEditForm',el));for(const field of ['cpus','memory','restart']){const value=fd.get(field);if(value)await request(`/docker/containers/${encodeURIComponent(name)}`,{method:'PATCH',form:{field,value}});}m.hide();toast(`${name} updated`);await renderRoute();}});
    if(metrics) renderContainerMetrics(metrics,name);
    startDetailMetrics(`/docker/containers/${encodeURIComponent(name)}/metrics`,m=>renderContainerMetrics(m,name));
    $('#detailsLogsBtn', $('#formModal')).onclick=()=>openContainerLogs(name);
    $('#detailsCommitBtn', $('#formModal')).onclick=()=>openCommitContainer(name);
    const terminalBtn=$('#detailsTerminalBtn', $('#formModal')); if(terminalBtn) terminalBtn.onclick=()=>openContainerTerminal(name);
  }

  async function loadVMImages(){
    const images=await request('/images'); state.cache.vmImages=images;
    const rows=images.map(i=>`<tr><td><div class="resource-name">${esc(i.name)}</div></td><td>${bytes(i.bytes)}</td><td><div class="action-row"><button class="btn btn-sm btn-outline-danger" data-vmi-delete="${esc(i.name)}">Delete</button></div></td></tr>`);
    const body=`<div class="upload-drop mb-4"><form id="isoUploadForm" class="row g-3 align-items-end"><div class="col-md-9"><label class="form-label">Upload ISO or disk image</label><input id="isoFile" type="file" class="form-control" accept=".iso,.img,.qcow2,.raw,.vmdk,.vhd,.vhdx"></div><div class="col-md-3 d-grid"><button class="btn btn-primary" type="submit">Upload</button></div><div id="isoUploadProgress" class="col-12 d-none" aria-live="polite"><div class="d-flex justify-content-between small mb-1"><span id="isoUploadStatus">Preparing upload</span><span id="isoUploadPercent">0%</span></div><div class="progress" role="progressbar" aria-label="Image upload progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><div id="isoUploadBar" class="progress-bar progress-bar-striped progress-bar-animated" style="width:0%"></div></div></div></form></div>${table(['Image','Size',''],rows,'No shared VM images have been uploaded.')}`;
    $('#view').innerHTML=card('VM images',body);
    $('#isoUploadForm').onsubmit=async e=>{e.preventDefault();const f=$('#isoFile').files[0];if(!f)return;const btn=$('button[type=submit]',e.currentTarget);btn.disabled=true;btn.textContent='Uploading…';try{await request(`/images/${encodeURIComponent(f.name)}`,{method:'PUT',body:f,headers:{'Content-Type':'application/octet-stream'}});toast(`${f.name} uploaded`);await renderRoute();}catch(err){toast(err.message,'Upload failed');}finally{btn.disabled=false;btn.textContent='Upload';}};
    $('#isoUploadForm').onsubmit=async e=>{e.preventDefault();const f=$('#isoFile').files[0];if(!f)return;const btn=$('button[type=submit]',e.currentTarget),progress=$('#isoUploadProgress'),bar=$('#isoUploadBar'),status=$('#isoUploadStatus'),percentEl=$('#isoUploadPercent');btn.disabled=true;btn.textContent='Uploading';progress.classList.remove('d-none');try{await uploadFile(`/images/${encodeURIComponent(f.name)}`,f,(loaded,total,known)=>{const value=known&&total?Math.round(loaded/total*100):0;bar.style.width=`${value}%`;bar.parentElement.setAttribute('aria-valuenow',String(value));percentEl.textContent=known?`${value}%`:'Uploading';status.textContent=known?`${f.name} - ${bytes(loaded)} of ${bytes(total)}`:`Uploading ${f.name}`;});toast(`${f.name} uploaded`);await renderRoute();}catch(err){toast(err.message,'Upload failed');}finally{btn.disabled=false;btn.textContent='Upload';}};
    $$('[data-vmi-delete]').forEach(b=>b.onclick=()=>confirmAction('Delete VM image',`Delete ${b.dataset.vmiDelete}?`,async()=>{await request(`/images/${encodeURIComponent(b.dataset.vmiDelete)}`,{method:'DELETE'});await renderRoute();}));
  }

  async function loadDockerImages(){
    const images=await request('/docker/images'); state.cache.dockerImages=images;
    const rows=images.map(i=>{const ref=(i.Repository&&i.Tag&&i.Repository!=='<none>'&&i.Tag!=='<none>')?`${i.Repository}:${i.Tag}`:(i.ID||'');return `<tr><td><div class="resource-name mono">${esc(ref)}</div><div class="small text-secondary mono">${esc(i.ID||'')}</div></td><td>${esc(i.Size||'')}</td><td>${esc(i.CreatedSince||i.CreatedAt||'')}</td><td><div class="action-row"><button class="btn btn-sm btn-outline-danger" data-di-delete="${esc(ref)}">Remove</button></div></td></tr>`;});
    $('#view').innerHTML=card('Docker images',table(['Repository / tag','Size','Created',''],rows,'No Docker images are present.'),`<button class="btn btn-sm btn-primary" id="pullImageBtn">Pull image</button>`);
    $('#pullImageBtn').onclick=()=>modal({eyebrow:'Docker registry',title:'Pull image',submitText:'Pull',size:'sm',body:`<form id="pullForm"><label class="form-label">Image reference</label><input name="image" class="form-control mono" placeholder="alpine:latest"></form>`,onSubmit:async(el,m)=>{const image=new FormData($('#pullForm',el)).get('image');await request('/docker/images/pull',{method:'POST',form:{image}});m.hide();toast(`${image} pulled`);await renderRoute();}});
    $$('[data-di-delete]').forEach(b=>b.onclick=()=>confirmAction('Remove Docker image',`Remove ${b.dataset.diDelete}?`,async()=>{await request(`/docker/images?image=${encodeURIComponent(b.dataset.diDelete)}`,{method:'DELETE'});await renderRoute();}));
  }

  async function openStorageLocations(){
    const storage=await request('/storage');
    const paths={config:storage.config_path||'',disks:storage.disk_path||'',isos:storage.iso_path||''};
    modal({eyebrow:'VM storage',title:'Storage locations',submitText:'Move storage',submitClass:'btn-warning',body:`<div class="alert alert-warning small">Moving a location transfers its current contents and updates the host configuration. Every VM must be stopped, the new location must be an unused absolute path, and a cross-filesystem move can take time.</div><div class="row g-3 mb-4"><div class="col-md-4"><div class="border rounded-3 p-3 h-100"><div class="small text-secondary">VM configuration</div><div class="mono small text-break mt-1">${esc(paths.config)}</div></div></div><div class="col-md-4"><div class="border rounded-3 p-3 h-100"><div class="small text-secondary">Virtual disks</div><div class="mono small text-break mt-1">${esc(paths.disks)}</div></div></div><div class="col-md-4"><div class="border rounded-3 p-3 h-100"><div class="small text-secondary">ISO media</div><div class="mono small text-break mt-1">${esc(paths.isos)}</div></div></div></div><form id="storageLocationForm"><div class="row g-3"><div class="col-md-4"><label class="form-label">Storage area</label><select name="kind" class="form-select"><option value="config">VM configuration</option><option value="disks">Virtual disks</option><option value="isos">ISO media</option></select></div><div class="col-md-8"><label class="form-label">New absolute location</label><input name="path" class="form-control mono" value="${esc(paths.config)}" required></div></div></form>`,onSubmit:async(el,m)=>{const form=$('#storageLocationForm',el),fd=new FormData(form),kind=fd.get('kind'),path=fd.get('path');if(!window.confirm(`Move ${kind} storage to ${path}?`))return;await request('/storage',{method:'POST',form:{kind,path}});m.hide();toast(`${kind} storage moved`);await renderRoute();}});
    const form=$('#storageLocationForm',$('#formModal'));form.kind.onchange=()=>{form.path.value=paths[form.kind.value];};
  }

  async function openISOMediaLibrary(){
    const images=await request('/images'); state.cache.vmImages=images;
    const rows=images.map(i=>`<tr><td><div class="resource-name">${esc(i.name)}</div></td><td>${bytes(i.bytes)}</td><td><div class="action-row"><button class="btn btn-sm btn-outline-secondary" data-iso-download="${esc(i.name)}">Download</button><button class="btn btn-sm btn-outline-danger" data-vmi-delete="${esc(i.name)}">Delete</button></div></td></tr>`);
    modal({eyebrow:'VM storage',title:'ISO installation media',body:`<div class="alert alert-light border small">Shared, read-only installation media is stored separately from VM configurations and virtual disks.</div><form id="isoLibraryForm" class="row g-3 align-items-end mb-4"><div class="col-md-9"><label class="form-label">Upload ISO or installer image</label><input id="isoLibraryFile" type="file" class="form-control" accept=".iso,.img"></div><div class="col-md-3 d-grid"><button class="btn btn-primary" type="submit">Upload</button></div><div id="isoLibraryProgress" class="col-12 d-none"><div class="d-flex justify-content-between small mb-1"><span id="isoLibraryStatus">Preparing upload</span><span id="isoLibraryPercent">0%</span></div><div class="progress"><div id="isoLibraryBar" class="progress-bar progress-bar-striped progress-bar-animated" style="width:0%"></div></div></div></form>${table(['Media','Size',''],rows,'No ISO installation media has been uploaded.')}`});
    $('#isoLibraryForm').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,file=$('#isoLibraryFile',form).files[0];if(!file)return;const btn=$('button',form),progress=$('#isoLibraryProgress'),bar=$('#isoLibraryBar'),status=$('#isoLibraryStatus'),percentEl=$('#isoLibraryPercent');btn.disabled=true;btn.textContent='Uploading';progress.classList.remove('d-none');try{await uploadFile(`/images/${encodeURIComponent(file.name)}`,file,(loaded,total,known)=>{const value=known&&total?Math.round(loaded/total*100):0;bar.style.width=`${value}%`;percentEl.textContent=known?`${value}%`:'Uploading';status.textContent=known?`${file.name} - ${bytes(loaded)} of ${bytes(total)}`:`Uploading ${file.name}`;});toast(`${file.name} uploaded`);await openISOMediaLibrary();}catch(err){toast(err.message,'Upload failed');}finally{btn.disabled=false;btn.textContent='Upload';}};
    $$('[data-iso-download]', $('#formModal')).forEach(b=>b.onclick=()=>downloadFile(`/images/${encodeURIComponent(b.dataset.isoDownload)}`));
    $$('[data-vmi-delete]', $('#formModal')).forEach(b=>b.onclick=async()=>{if(!window.confirm(`Delete ${b.dataset.vmiDelete}?`))return;await request(`/images/${encodeURIComponent(b.dataset.vmiDelete)}`,{method:'DELETE'});toast(`${b.dataset.vmiDelete} deleted`);await openISOMediaLibrary();});
  }

  async function openVMDiskStorage(){
    const names=await request('/vms'); const vms=await Promise.all(names.map(v=>request(`/vms/${encodeURIComponent(v.name)}`)));
    const rows=vms.flatMap(vm=>indexedConfig(vm.config||{},'DISK',['FILE','FORMAT','BUS']).map(d=>`<tr><td>${esc(vm.name)}</td><td class="mono">${esc(d.FILE)}</td><td>${esc(d.FORMAT)}</td><td>${esc(d.BUS)}</td><td class="mono small text-break">${esc(`${vm.storage?.disk_path || ''}/${d.FILE}`)}</td><td><button class="btn btn-sm btn-outline-secondary" data-vm-disk-download="${esc(vm.name)}" data-vm-disk-index="${d.index}">Download</button></td></tr>`));
    const options=vms.map(vm=>`<option value="${esc(vm.name)}">${esc(vm.name)}</option>`).join('');
    modal({eyebrow:'VM storage',title:'Virtual disks',size:'xl',body:`<div class="alert alert-light border small">Each VM has its own disk folder. Uploading a QCOW2, RAW, or VMDK stores it there and attaches it as a new data disk. The VM must be stopped.</div><form id="diskLibraryForm" class="row g-3 align-items-end mb-4"><div class="col-md-3"><label class="form-label">Virtual machine</label><select name="vm" class="form-select" required><option value="">Select VM</option>${options}</select></div><div class="col-md-4"><label class="form-label">Disk file</label><input id="diskLibraryFile" type="file" class="form-control" accept=".qcow2,.raw,.vmdk" required></div><div class="col-md-2"><label class="form-label">Format</label><select name="format" class="form-select"><option>qcow2</option><option>raw</option><option>vmdk</option></select></div><div class="col-md-2"><label class="form-label">Bus</label><select name="bus" class="form-select"><option>virtio</option><option>sata</option><option>scsi</option></select></div><div class="col-md-1 d-grid"><button class="btn btn-primary" type="submit">Upload</button></div><div id="diskLibraryProgress" class="col-12 d-none"><div class="d-flex justify-content-between small mb-1"><span id="diskLibraryStatus">Preparing upload</span><span id="diskLibraryPercent">0%</span></div><div class="progress"><div id="diskLibraryBar" class="progress-bar progress-bar-striped progress-bar-animated" style="width:0%"></div></div></div></form>${table(['VM','Disk','Format','Bus','Storage location',''],rows,'No virtual disks are attached.')}`});
    $('#diskLibraryForm').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,fd=new FormData(form),file=$('#diskLibraryFile',form).files[0],vm=fd.get('vm');if(!file||!vm)return;const btn=$('button',form),progress=$('#diskLibraryProgress'),bar=$('#diskLibraryBar'),status=$('#diskLibraryStatus'),percentEl=$('#diskLibraryPercent');btn.disabled=true;btn.textContent='Uploading';progress.classList.remove('d-none');try{const q=new URLSearchParams({format:fd.get('format'),bus:fd.get('bus')});await uploadFile(`/vms/${encodeURIComponent(vm)}/disks/import/${encodeURIComponent(file.name)}?${q}`,file,(loaded,total,known)=>{const value=known&&total?Math.round(loaded/total*100):0;bar.style.width=`${value}%`;percentEl.textContent=known?`${value}%`:'Uploading';status.textContent=known?`${file.name} - ${bytes(loaded)} of ${bytes(total)}`:`Uploading ${file.name}`;});toast(`${file.name} attached to ${vm}`);await openVMDiskStorage();}catch(err){toast(err.message,'Disk upload failed');}finally{btn.disabled=false;btn.textContent='Upload';}};
    $$('[data-vm-disk-download]', $('#formModal')).forEach(b=>b.onclick=()=>downloadFile(`/vms/${encodeURIComponent(b.dataset.vmDiskDownload)}/disks/${encodeURIComponent(b.dataset.vmDiskIndex)}/download`));
  }

  async function openDockerImageLibrary(){
    const images=await request('/docker/images'); state.cache.dockerImages=images;
    const rows=images.map(i=>{const ref=(i.Repository&&i.Tag&&i.Repository!=='<none>'&&i.Tag!=='<none>')?`${i.Repository}:${i.Tag}`:(i.ID||'');return `<tr><td><div class="resource-name mono">${esc(ref)}</div><div class="small text-secondary mono">${esc(i.ID||'')}</div></td><td>${esc(i.Size||'')}</td><td>${esc(i.CreatedSince||i.CreatedAt||'')}</td><td><button class="btn btn-sm btn-outline-danger" data-library-image-delete="${esc(ref)}">Remove</button></td></tr>`;});
    modal({eyebrow:'Docker registry',title:'Container image library',body:`<section class="border rounded-3 p-3 mb-4"><div class="form-section-title mb-2">Pull an image</div><form id="pullLibraryForm" class="row g-2"><div class="col-sm-9"><label class="form-label">Image reference</label><input name="image" class="form-control mono" placeholder="alpine:latest" required></div><div class="col-sm-3 d-grid align-self-end"><button class="btn btn-primary" type="submit">Pull image</button></div></form><pre id="dockerImageOutput" class="code-panel mt-3 mb-0" style="display:none;min-height:0;max-height:12rem"></pre></section>${table(['Repository / tag','Size','Created',''],rows,'No Docker images are present.')}`});
    $('#pullLibraryForm').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,image=new FormData(form).get('image'),btn=$('button',form),out=$('#dockerImageOutput');btn.disabled=true;btn.textContent='Pulling…';out.style.display='block';out.textContent=`$ docker pull ${image}\n`;try{const result=await request('/docker/images/pull',{method:'POST',form:{image}});out.textContent+=result.output || 'Pull complete.';toast(`${image} pulled`);}catch(err){out.textContent+=err.message;toast(err.message,'Pull failed');}finally{btn.disabled=false;btn.textContent='Pull image';}};
    $$('[data-library-image-delete]', $('#formModal')).forEach(b=>b.onclick=async()=>{const ref=b.dataset.libraryImageDelete;if(!window.confirm(`Remove ${ref}?`))return;const out=$('#dockerImageOutput');out.style.display='block';out.textContent=`$ docker image rm ${ref}\n`;try{const result=await request(`/docker/images?image=${encodeURIComponent(ref)}`,{method:'DELETE'});out.textContent+=result.output || 'Image removed.';toast(`${ref} removed`);}catch(err){out.textContent+=err.message;if(!window.confirm(`${ref} is still referenced. Force removal removes its local tag even when a container uses it. Continue?`)){toast(err.message,'Removal failed');return;}try{out.textContent+=`\n$ docker image rm --force ${ref}\n`;const result=await request(`/docker/images?image=${encodeURIComponent(ref)}&force=true`,{method:'DELETE'});out.textContent+=result.output || 'Image force-removed.';toast(`${ref} force-removed`);}catch(forceErr){out.textContent+=forceErr.message;toast(forceErr.message,'Force removal failed');}}});
  }

  const bridgeWarning = `<div class="alert alert-warning small mb-3"><strong>This can disrupt connectivity.</strong><div class="mt-1">Changing bridge members, addresses, or the default gateway can disconnect this host from the network. Do not attach the active management interface unless you have another way back in.</div></div>`;
  function bridgeMemberOptions(host, selected = []) {
    const selectedSet = new Set(selected || []);
    return (host.interfaces || []).filter(i => !['lo','docker0'].includes(i) && !/^(tap|vnet)\d+$/.test(i)).map(i=>`<option value="${esc(i)}" ${selectedSet.has(i)?'selected':''}>${esc(i)}</option>`).join('');
  }
  function bridgeFormBody(host, bridge = null) {
    const members = bridge?.members || [];
    return `<form id="bridgeForm">${bridgeWarning}<div class="row g-3"><div class="col-md-6"><label class="form-label">Bridge name</label><input name="name" class="form-control mono" value="${esc(bridge?.name || '')}" placeholder="br0" ${bridge?'readonly':''} required></div><div class="col-md-6"><label class="form-label">Address mode</label><select name="address_mode" id="bridgeAddressMode" class="form-select"><option value="manual">No host address</option><option value="static">Static address</option><option value="dhcp">DHCP</option></select></div><div class="col-md-6" id="bridgeAddressWrap"><label class="form-label">Bridge address</label><input name="address" class="form-control mono" value="${esc(bridge?.addresses?.[0] || '')}" placeholder="10.0.4.10/24"></div><div class="col-md-6"><label class="form-label">Gateway</label><input name="gateway" class="form-control mono" value="${esc(bridge?.gateway || '')}" placeholder="10.0.4.1"></div><div class="col-md-6"><label class="form-label">Member interfaces</label><select name="member" multiple size="4" class="form-select mono">${bridgeMemberOptions(host, members)}</select></div><div class="col-12"><div class="form-check form-switch mb-2"><input name="persist" id="bridgePersist" class="form-check-input" type="checkbox" ${bridge?.persist === false ? '' : 'checked'}><label class="form-check-label" for="bridgePersist">Persist across reboot</label></div><div class="form-check"><input name="ack" id="bridgeAck" class="form-check-input" type="checkbox" required><label class="form-check-label" for="bridgeAck">I understand this may disrupt host connectivity.</label></div></div></div></form>`;
  }
  async function openCreateBridge(host) {
    modal({eyebrow:'Linux bridge',title:'Create host bridge',submitText:'Create bridge',body:bridgeFormBody(host),onSubmit:async(el,m)=>{const fd=new FormData($('#bridgeForm',el));const mode=fd.get('address_mode');const o={name:fd.get('name'),address:mode==='static'?fd.get('address'):'',dhcp:mode==='dhcp'?'true':'false',manual:mode==='manual'?'true':'false',gateway:fd.get('gateway'),member:fd.getAll('member'),persist:fd.has('persist')?'true':'false'};await request('/networks',{method:'POST',form:o});m.hide();toast(`${o.name} created`);await renderRoute();}});
    bindBridgeAddressMode($('#formModal'));
  }
  async function openEditBridge(host, name) {
    const bridge = await request(`/networks?name=${encodeURIComponent(name)}`);
    modal({eyebrow:'Linux bridge',title:`Edit ${name}`,submitText:'Save bridge',submitClass:'btn-warning',body:bridgeFormBody(host, bridge),onSubmit:async(el,m)=>{const fd=new FormData($('#bridgeForm',el));const mode=fd.get('address_mode');const o={name:fd.get('name'),address:mode==='static'?fd.get('address'):'',dhcp:mode==='dhcp'?'true':'false',manual:mode==='manual'?'true':'false',gateway:fd.get('gateway'),member:fd.getAll('member'),persist:fd.has('persist')?'true':'false'};await request('/networks',{method:'PATCH',form:o});m.hide();toast(`${o.name} updated`);await renderRoute();}});
    bindBridgeAddressMode($('#formModal'));
  }

  function bindBridgeAddressMode(root) {
    const mode = $('#bridgeAddressMode', root); const wrap = $('#bridgeAddressWrap', root); const address = $('input[name="address"]', root);
    const sync = () => { const staticMode = mode.value === 'static'; wrap.classList.toggle('d-none', !staticMode); if (!staticMode) address.value = ''; };
    mode.addEventListener('change', sync); sync();
  }

  async function loadNetworks(){
    const [host,dockerNets,overlays]=await Promise.all([request('/networks'),request('/docker/networks'),request('/overlays')]);
    const overlayBridges=new Set((overlays||[]).map(o=>o.bridge));
    const dockerByName=new Map((dockerNets||[]).map(n=>[n.Name,n]));
    const actions=(kind,name)=>`<div class="action-row"><button class="btn btn-sm btn-outline-primary" data-network-edit="${esc(kind)}:${esc(name)}">Edit</button>${kind!=='interface'?`<button class="btn btn-sm btn-outline-danger" data-network-delete="${esc(kind)}:${esc(name)}">Delete</button>`:''}</div>`;
    const rows=[];
    (overlays||[]).forEach(o=>{const checks=`TAP ${esc(o.tap_type||'missing')} · process ${o.tap_process?'up':'down'} · bridge ${o.tap_bridged?'attached':'detached'}${o.docker_network_conflict?'<div class="small text-warning">Legacy Docker network conflicts with this Layer-2 segment</div>':''}`;rows.push(`<tr><td><div class="resource-name mono">${esc(o.name)}</div><div class="small text-secondary mono">${esc(o.bridge)}</div></td><td><span class="badge text-bg-primary">Overlay</span></td><td>${esc(o.role)} · ${(o.peers||[]).length} peer${(o.peers||[]).length===1?'':'s'}<div class="small text-secondary mono">${esc(o.relay_path||'')}</div><div class="small text-secondary">${checks}</div></td><td>${stateBadge(o.running?'ready':'needs attention')}</td><td><div class="action-row"><button class="btn btn-sm btn-outline-secondary" data-overlay-validate="${esc(o.name)}">Validate</button>${actions('overlay',o.name)}</div></td></tr>`);});
    (host.bridges||[]).filter(b=>!overlayBridges.has(b)).forEach(b=>rows.push(`<tr><td><div class="resource-name mono">${esc(b)}</div></td><td><span class="badge text-bg-dark">Linux bridge</span></td><td>Host Layer-2 bridge</td><td>${stateBadge('available')}</td><td>${actions('bridge',b)}</td></tr>`));
    (dockerNets||[]).forEach(n=>rows.push(`<tr><td><div class="resource-name mono">${esc(n.Name||'')}</div><div class="small text-secondary mono">${esc((n.ID||'').slice(0,12))}</div></td><td><span class="badge text-bg-info">Docker</span></td><td>${esc(n.Driver||'')} · ${esc(n.Scope||'local')}</td><td>${stateBadge('available')}</td><td>${actions('docker',n.Name||'')}</td></tr>`));
    (host.interfaces||[]).filter(i=>!(host.bridges||[]).includes(i)).forEach(i=>rows.push(`<tr><td><div class="resource-name mono">${esc(i)}</div></td><td><span class="badge text-bg-secondary">Interface</span></td><td>Host network adapter</td><td>${stateBadge('detected')}</td><td>${actions('interface',i)}</td></tr>`));

    $('#view').innerHTML=card('Networks',`<div class="small text-secondary mb-3">Host adapters, Linux bridges, Docker networks, and GOST TAP overlays are managed from one inventory. Each network type opens its own configuration dialog.</div>${table(['Name','Type','Configuration','State','Actions'],rows,'No networks or interfaces detected.')}`,`<button class="btn btn-sm btn-primary" id="createNetworkBtn">Create network</button>`);

    const openOverlay=async(existing=null)=>{const peers=(await request('/cluster/peers')).filter(p=>p.relay_configured&&p.url);modal({eyebrow:'GOST TAP over WebSocket',title:existing?`Edit ${existing.name}`:'Create overlay network',submitText:existing?'Recreate overlay':'Create overlay',body:`<form id="networkOverlayForm">${existing?'<div class="alert alert-warning small">Overlay transport settings are applied by recreating the overlay. Attached workloads must be disconnected first.</div>':''}<div class="row g-3"><div class="col-md-6"><label class="form-label">Network name</label><input name="name" class="form-control mono" maxlength="11" value="${esc(existing?.name||'')}" ${existing?'readonly':''} required></div><div class="col-md-6"><label class="form-label">Linux bridge</label><input name="bridge" class="form-control mono" value="${esc(existing?.bridge||'')}" required></div><div class="col-md-6"><label class="form-label">Topology role</label><select name="role" class="form-select"><option value="hub" ${existing?.role==='hub'?'selected':''}>Hub — accepts multiple peers</option><option value="spoke" ${existing?.role==='spoke'?'selected':''}>Spoke — connects to one hub</option></select></div><div class="col-md-6"><label class="form-label">MTU</label><input name="mtu" type="number" min="1200" max="1499" value="1400" class="form-control"></div><div class="col-12"><label class="form-label">Paired hosts</label><select name="peers" multiple size="${Math.max(3,Math.min(7,peers.length))}" class="form-select" required>${peers.map(p=>`<option value="${esc(p.node_id)}" ${(existing?.peers||[]).includes(p.node_id)?'selected':''}>${esc(p.name||p.node_id)}</option>`).join('')}</select><div class="form-text">Spokes require exactly one hub. Hubs may select multiple paired hosts. Traffic uses TAP Ethernet frames over the peer's existing HTTP(S) WebSocket endpoint.</div></div></div></form>`,onSubmit:async(el,m)=>{const f=new FormData($('#networkOverlayForm',el));const selected=[...$('select[name="peers"]',el).selectedOptions];if(!selected.length)throw new Error('Select at least one paired host.');if(f.get('role')==='spoke'&&selected.length!==1)throw new Error('A spoke must select exactly one hub.');if(existing)await request(`/overlays/${encodeURIComponent(existing.name)}`,{method:'DELETE'});const form={name:f.get('name'),bridge:f.get('bridge'),role:f.get('role'),mtu:f.get('mtu')};selected.forEach((p,i)=>form[`peer_${i}`]=p.value);await request('/overlays',{method:'POST',form});m.hide();toast(`${f.get('name')} saved`);await renderRoute();}});};
    const openDocker=async(name='')=>{let current={};if(name)current=first(await request(`/docker/networks/${encodeURIComponent(name)}`))||{};const ipam=current.IPAM?.Config?.[0]||{};modal({eyebrow:'Docker network',title:name?`Edit ${name}`:'Create Docker network',submitText:name?'Recreate network':'Create network',body:`<form id="networkDockerForm">${name?'<div class="alert alert-warning small">Docker network addressing is immutable. Saving removes and recreates an unused network.</div>':''}<div class="row g-3"><div class="col-md-6"><label class="form-label">Name</label><input name="name" class="form-control mono" value="${esc(name)}" ${name?'readonly':''} required></div><div class="col-md-6"><label class="form-label">Driver</label><input name="driver" class="form-control" value="${esc(current.Driver||'bridge')}" required></div><div class="col-md-6"><label class="form-label">Subnet</label><input name="subnet" class="form-control mono" value="${esc(ipam.Subnet||'')}" placeholder="172.30.0.0/24"></div><div class="col-md-6"><label class="form-label">Gateway</label><input name="gateway" class="form-control mono" value="${esc(ipam.Gateway||'')}" placeholder="172.30.0.1"></div><div class="col-12 form-check form-switch ms-2"><input name="internal" id="networkInternal" class="form-check-input" type="checkbox" ${current.Internal?'checked':''}><label class="form-check-label" for="networkInternal">Internal-only network</label></div></div></form>`,onSubmit:async(el,m)=>{const f=new FormData($('#networkDockerForm',el));const form={name:f.get('name'),driver:f.get('driver'),subnet:f.get('subnet'),gateway:f.get('gateway'),internal:f.has('internal')?'true':'false'};if(name)await request(`/docker/networks/${encodeURIComponent(name)}`,{method:'DELETE'});await request('/docker/networks',{method:'POST',form});m.hide();toast(`${form.name} saved`);await renderRoute();}});};
    const openCreate=()=>modal({eyebrow:'Networking',title:'Create network',submitText:'Continue',size:'sm',body:`<form id="networkKindForm"><label class="form-label">Network type</label><select name="kind" class="form-select"><option value="bridge">Linux bridge</option><option value="docker">Docker network</option><option value="overlay">GOST TAP overlay</option></select><div class="form-text mt-2">The next dialog contains only settings relevant to the selected network type.</div></form>`,onSubmit:async(el,m)=>{const kind=new FormData($('#networkKindForm',el)).get('kind');m.hide();setTimeout(()=>kind==='bridge'?openCreateBridge(host):kind==='docker'?openDocker():openOverlay(),200);}});
    $('#createNetworkBtn').onclick=openCreate;
    $$('[data-overlay-validate]').forEach(b=>b.onclick=async()=>{const name=encodeURIComponent(b.dataset.overlayValidate);const result=await request(`/overlays/${name}`);const checks=[['GOST process',result.tap_process],['TAP adapter',result.tap_type==='tap'],['TAP link up',result.tap_up],['Attached to bridge',result.tap_bridged]];modal({eyebrow:'Layer-2 validation',title:result.name,body:table(['Check','Result'],checks.map(([label,ok])=>`<tr><td>${esc(label)}</td><td>${ok?'<span class="text-success">Pass</span>':'<span class="text-danger">Fail</span>'}</td></tr>`),'')});});
    $$('[data-network-edit]').forEach(b=>b.onclick=async()=>{const [kind,name]=b.dataset.networkEdit.split(':');if(kind==='bridge')return openEditBridge(host,name);if(kind==='docker')return openDocker(name);if(kind==='overlay')return openOverlay((overlays||[]).find(o=>o.name===name));modal({eyebrow:'Host adapter',title:name,submitText:'Create bridge',body:`<div class="alert alert-info small">Physical adapters are managed by the operating system. To use this adapter with VMs, create a Linux bridge and select <span class="mono">${esc(name)}</span> as its member.</div>`,onSubmit:async(_el,m)=>{m.hide();setTimeout(()=>openCreateBridge(host),200);}});});
    $$('[data-network-delete]').forEach(b=>b.onclick=()=>{const [kind,name]=b.dataset.networkDelete.split(':');const action=kind==='bridge'?()=>request(`/networks?name=${encodeURIComponent(name)}`,{method:'DELETE'}):kind==='docker'?()=>request(`/docker/networks/${encodeURIComponent(name)}`,{method:'DELETE'}):()=>request(`/overlays/${encodeURIComponent(name)}`,{method:'DELETE'});confirmAction(`Delete ${kind} network`,`Delete ${name}? Attached workloads must be disconnected first.`,async()=>{await action();toast(`${name} deleted`);await renderRoute();});});
  }

  async function loadVolumes(){
    const vols=await request('/docker/volumes');
    const rows=vols.map(v=>`<tr><td><div class="resource-name">${esc(v.Name||'')}</div></td><td>${esc(v.Driver||'')}</td><td>${esc(v.Scope||'')}</td><td><div class="action-row"><button class="btn btn-sm btn-outline-secondary" data-vol-inspect="${esc(v.Name||'')}">Inspect</button><button class="btn btn-sm btn-outline-danger" data-vol-delete="${esc(v.Name||'')}">Delete</button></div></td></tr>`);
    $('#view').innerHTML=card('Docker volumes',table(['Name','Driver','Scope',''],rows,'No Docker volumes found.'),`<button class="btn btn-sm btn-primary" id="createVolBtn">Create volume</button>`);
    $('#createVolBtn').onclick=()=>modal({eyebrow:'Docker daemon',title:'Create volume',submitText:'Create',size:'sm',body:`<form id="volForm"><label class="form-label">Name</label><input name="name" class="form-control mb-3"><label class="form-label">Driver</label><input name="driver" class="form-control" placeholder="local"></form>`,onSubmit:async(el,m)=>{const o=Object.fromEntries(new FormData($('#volForm',el)).entries());await request('/docker/volumes',{method:'POST',form:o});m.hide();await renderRoute();}});
    $$('[data-vol-delete]').forEach(b=>b.onclick=()=>confirmAction('Delete Docker volume',`Delete ${b.dataset.volDelete}?`,async()=>{await request(`/docker/volumes/${encodeURIComponent(b.dataset.volDelete)}`,{method:'DELETE'});await renderRoute();}));
    $$('[data-vol-inspect]').forEach(b=>b.onclick=async()=>{const d=await request(`/docker/volumes/${encodeURIComponent(b.dataset.volInspect)}`);modal({eyebrow:'Docker volume',title:b.dataset.volInspect,body:`<pre class="code-panel mb-0">${esc(JSON.stringify(first(d),null,2))}</pre>`});});
  }

  async function loadCluster() {
    const local={local:true};
    const [identity, peers, pending] = await Promise.all([request('/cluster/identity',local), request('/cluster/peers',local), request('/cluster/pair/pending',local).catch(()=>null)]);
    state.hostCatalog = buildHostCatalog(identity, peers);
    renderHostSelector();
    const rows = (peers || []).map(p => `<tr><td class="mono">${esc(p.name || '')}</td><td class="mono small">${esc(p.node_id || '')}</td><td><div class="mono small">${esc(p.url || 'Not configured')}</div><div class="small text-secondary">${esc(p.api_auth || 'basic')} · ${esc((p.public_key_fingerprint || '').slice(0,16))}…</div></td><td><div class="action-row"><button class="btn btn-sm btn-outline-primary" data-peer-manage="${esc(p.node_id || '')}">Manage</button><button class="btn btn-sm btn-outline-secondary" data-peer-url="${esc(p.node_id || '')}" data-peer-name="${esc(p.name || '')}" data-peer-current-url="${esc(p.url || '')}">Endpoint</button>${hasCap('vm-network')?`<button class="btn btn-sm btn-outline-secondary" data-peer-relay="${esc(p.node_id || '')}" data-peer-name="${esc(p.name || '')}">Relay</button>`:''}<button class="btn btn-sm btn-outline-danger" data-peer-revoke="${esc(p.node_id || '')}">Revoke</button></div></td></tr>`);
    $('#view').innerHTML = card('Cluster peers', `<div class="small text-secondary mb-3">This node: <span class="mono">${esc(identity.name || '')}</span> · <span class="mono">${esc(identity.node_id || '')}</span>. Complete the pairing request and response exchange first. Each pair receives one HTTP Basic credential used for peer API requests and hub WebSocket upgrades.</div><div id="clusterFeedback" class="mb-3" aria-live="polite"></div><div id="clusterExportResult" class="mb-3"></div><div id="clusterResponseResult" class="mb-3"></div>${table(['Peer','Node ID','API endpoint / key',''], rows, 'No trusted peers.')}`, `<button class="btn btn-sm btn-primary" id="peerRequestBtn">Export pairing request</button><button class="btn btn-sm btn-outline-secondary ms-2" id="peerAcceptBtn">Import pairing request</button><button class="btn btn-sm btn-outline-secondary ms-2" id="peerCompleteBtn">Import pairing response</button>`);
    const detectedEndpoint=`${location.protocol}//${location.host}`;
    $('#peerRequestBtn').onclick=()=>modal({eyebrow:'Cluster trust',title:'Export pairing request',submitText:'Create request',size:'sm',body:`<form id="peerRequestForm"><label class="form-label">This host's pairing name</label><input name="name" class="form-control mono mb-2" value="${esc(identity.name||'')}" required maxlength="64" autofocus><div class="form-text mb-3">Detected from this host. Change it if you want the pairing credential to use a different label.</div><label class="form-label">This host's API endpoint</label><input name="endpoint" type="url" class="form-control mono" value="${esc(detectedEndpoint)}" required><div class="form-text">Detected from this browser URL. This signed endpoint lets the peer authenticate API calls after pairing.</div></form>`,onSubmit:async(el,m)=>{const form=new FormData($('#peerRequestForm',el));const bundle=await request('/cluster/pair/request',{method:'POST',form:{name:form.get('name'),endpoint:form.get('endpoint')},local:true});m.hide();setClusterFeedback('success','Pairing request created. Copy or download the credential below, then import it on the other host.');showClusterExport(bundle);}});
    $('#peerAcceptBtn').onclick=()=>openPairImport('Import pairing request','Accept request','/cluster/pair/accept','Pairing response','vmapi-pair-response.txt',identity.name||'');
    $('#peerCompleteBtn').onclick=()=>openPairImport('Import pairing response','Complete pairing','/cluster/pair/complete');
    $$('[data-peer-manage]').forEach(b=>b.onclick=()=>{location.hash=`#dashboard?peer=${encodeURIComponent(b.dataset.peerManage)}`;});
    $$('[data-peer-url]').forEach(b=>b.onclick=()=>modal({eyebrow:'Cluster peer',title:`Endpoint: ${b.dataset.peerName}`,submitText:'Save endpoint',size:'sm',body:`<form id="peerForm"><label class="form-label">Peer base URL</label><input name="url" class="form-control mono" value="${esc(b.dataset.peerCurrentUrl)}" placeholder="https://host-b.example" required><div class="form-text">Enter the public base URL, not <span class="mono">/api</span>. Paired API traffic uses the protected <span class="mono">/peer-api</span> path automatically.</div></form>`,onSubmit:async(el,m)=>{const url=new FormData($('#peerForm',el)).get('url');await request('/cluster/peer-url',{method:'PATCH',form:{node_id:b.dataset.peerUrl,url},local:true});m.hide();toast('Peer endpoint saved');await loadCluster();}}));
    $$('[data-peer-relay]').forEach(b=>b.onclick=async()=>{const credential=await request(`/cluster/peers/${encodeURIComponent(b.dataset.peerRelay)}/overlay-credentials`,local);modal({eyebrow:'Paired HTTP Basic credential',title:`Peer credential: ${b.dataset.peerName}`,body:`<div class="alert alert-info small">Overlay setup automatically uses this pairing credential for the peer API and the WebSocket upgrade. Lighttpd checks it on the hub.</div><label class="form-label">Username</label><input class="form-control mono mb-3" value="${esc(credential.username||'')}" readonly><label class="form-label">Password</label><input class="form-control mono" value="${esc(credential.password||'')}" readonly>`});});
    $$('[data-peer-revoke]').forEach(b=>b.onclick=()=>confirmAction('Revoke peer',`Revoke ${b.dataset.peerRevoke}?`,async()=>{await request(`/cluster/peers/${encodeURIComponent(b.dataset.peerRevoke)}`,{method:'DELETE',local:true});await renderRoute();}));
    const pendingBundle = typeof pending === 'string' ? pending.trim() : '';
    if (pendingBundle) {
      setClusterFeedback('info','A pairing request is already pending. It will remain available until it expires or pairing completes.');
      showClusterExport(pendingBundle);
    }
  }

  function setClusterFeedback(kind, message, spinning=false) {
    const target = $('#clusterFeedback'); if (!target) return;
    const spinner = spinning ? '<span class="spinner-border spinner-border-sm me-2" aria-hidden="true"></span>' : '';
    target.innerHTML = `<div class="alert alert-${kind} d-flex align-items-center mb-0" role="status">${spinner}<span>${esc(message)}</span></div>`;
  }

  function showClusterExport(bundle) {
    const target = $('#clusterExportResult'); if (!target) return;
    target.innerHTML = `<div class="border rounded-3 p-3 bg-body-tertiary">${pairingBundleDetails(bundle)}<label for="clusterPairBundle" class="form-label fw-semibold">Pairing request</label><textarea id="clusterPairBundle" class="form-control mono" rows="10" readonly>${esc(bundle)}</textarea><div class="d-flex flex-wrap gap-2 mt-3"><button id="copyClusterPairBundle" type="button" class="btn btn-sm btn-outline-primary">Copy request</button><button id="downloadClusterPairBundle" type="button" class="btn btn-sm btn-outline-secondary">Download file</button><button id="revokeClusterPairBundle" type="button" class="btn btn-sm btn-outline-danger">Revoke pending request</button></div></div>`;
    $('#copyClusterPairBundle', target).onclick=async()=>{try{await navigator.clipboard.writeText(bundle);toast('Pairing request copied');}catch{setClusterFeedback('warning','Copy was blocked by the browser. Select the request text and copy it manually.');}};
    $('#downloadClusterPairBundle', target).onclick=()=>{const url=URL.createObjectURL(new Blob([bundle],{type:'text/plain'}));const link=document.createElement('a');link.href=url;link.download='vmapi-pair-request.txt';link.click();URL.revokeObjectURL(url);};
    $('#revokeClusterPairBundle', target).onclick=()=>confirmAction('Revoke pending request','This permanently invalidates the displayed request. Any response created from it can no longer be completed.',async()=>{await request('/cluster/pair/pending',{method:'DELETE',local:true});toast('Pending pairing request revoked');await loadCluster();});
    target.scrollIntoView({behavior:'smooth',block:'nearest'});
  }

  function showClusterResponse(bundle) {
    const target = $('#clusterResponseResult'); if (!target) return;
    target.innerHTML = `<div class="border rounded-3 p-3 bg-body-tertiary">${pairingBundleDetails(bundle)}<div class="alert alert-success small">Pairing response generated. Copy or download this credential and import it on the originating host to complete trust.</div><label for="clusterPairResponse" class="form-label fw-semibold">Pairing response</label><textarea id="clusterPairResponse" class="form-control mono" rows="10" readonly>${esc(bundle)}</textarea><div class="d-flex flex-wrap gap-2 mt-3"><button id="copyClusterPairResponse" type="button" class="btn btn-sm btn-outline-primary">Copy response</button><button id="downloadClusterPairResponse" type="button" class="btn btn-sm btn-outline-secondary">Download file</button></div></div>`;
    $('#copyClusterPairResponse', target).onclick=async()=>{try{await navigator.clipboard.writeText(bundle);toast('Pairing response copied');}catch{setClusterFeedback('warning','Copy was blocked by the browser. Select the response text and copy it manually.');}};
    $('#downloadClusterPairResponse', target).onclick=()=>{const url=URL.createObjectURL(new Blob([bundle],{type:'text/plain'}));const link=document.createElement('a');link.href=url;link.download='vmapi-pair-response.txt';link.click();URL.revokeObjectURL(url);};
    target.scrollIntoView({behavior:'smooth',block:'nearest'});
  }

  function pairingBundleDetails(bundle) {
    try {
      const raw=atob(String(bundle||'').trim()); const fields={}; raw.split(/\r?\n/).forEach(line=>{const i=line.indexOf('=');if(i>0)fields[line.slice(0,i)]=line.slice(i+1);});
      if(!/^VMAPI-PAIR-(REQUEST|RESPONSE)-3/.test(raw))return '';
      const expiry=fields.EXPIRES?new Date(Number(fields.EXPIRES)*1000).toLocaleString():'';
      return `<div class="alert alert-info small mb-3"><div><strong>Host:</strong> <span class="mono">${esc(fields.NODE_NAME||'')}</span></div><div><strong>API endpoint:</strong> <span class="mono text-break">${esc(fields.API_ENDPOINT||'')}</span></div><div><strong>Node ID:</strong> <span class="mono">${esc(fields.NODE_ID||'')}</span></div><div><strong>Public-key fingerprint:</strong> <span class="mono text-break">${esc(fields.PUBLIC_FINGERPRINT||'')}</span></div><div><strong>Expires:</strong> ${esc(expiry)}</div><div class="mt-2">Confirm these details through an independent channel before accepting the bundle.</div></div>`;
    } catch { return '<div class="alert alert-warning small mb-3">This is not a readable VMAPI pairing bundle.</div>'; }
  }
  function openPairImport(title, submitText, path, responseTitle='', responseFile='', localName=null) {
    const localNameField = localName !== null ? `<label class="form-label">This host's pairing name</label><input name="name" class="form-control mono mb-2" value="${esc(localName)}" required maxlength="64" autofocus><div class="form-text mb-3">Detected from this host. Confirm it or replace it before generating this host's response.</div><label class="form-label">This host's API endpoint</label><input name="endpoint" type="url" class="form-control mono mb-2" value="${esc(`${location.protocol}//${location.host}`)}" required><div class="form-text mb-3">Detected from this browser URL. Confirm it or replace it; it will be signed into the pairing response.</div>` : '';
    modal({eyebrow:'Cluster trust',title,submitText,size:'lg',body:`<form id="peerForm">${localNameField}<label class="form-label">Pairing file</label><input id="pairFile" type="file" accept=".txt,text/plain" class="form-control mb-3"><label class="form-label">Or paste pairing bundle</label><textarea name="bundle" id="pairBundleInput" class="form-control mono" rows="10" required></textarea><div id="pairBundleDetails" class="mt-3"></div></form>`,onSubmit:async(el,m)=>{const form=new FormData($('#peerForm',el));const bundle=form.get('bundle');const payload={bundle};if(localName!==null){payload.name=form.get('name');payload.endpoint=form.get('endpoint');}const result=await request(path,{method:'POST',form:payload,local:true});m.hide();if(responseTitle){setClusterFeedback('success','Pairing request accepted. The response is ready below.');showClusterResponse(result);}else{toast('Peer trusted');await renderRoute();}}});
    const root=$('#formModal'); const input=$('#pairBundleInput',root); const update=()=>{$('#pairBundleDetails',root).innerHTML=input.value.trim()?pairingBundleDetails(input.value):'';};
    input.oninput=update; $('#pairFile',root).onchange=async event=>{const file=event.target.files[0];if(file){input.value=await file.text();update();}};
  }
  function watchBackupJob(job, root, name, onComplete = null) {
    const progress=$('#vmBackupProgress',root); const bar=$('#vmBackupProgressBar',root); const label=$('#vmBackupProgressLabel',root); const value=$('#vmBackupProgressValue',root); const button=$('#vmBackupNowBtn',root);
    progress.classList.remove('d-none');
    const update=async()=>{
      if(!document.body.contains(root) || !root.classList.contains('show')) return;
      try {
        const status=await request(`/backups/jobs/${encodeURIComponent(job.id)}`);
        const amount=Math.max(0,Math.min(100,Number(status.percent)||0));
        bar.style.width=`${amount}%`; bar.setAttribute('aria-valuenow',String(amount)); value.textContent=`${amount}%`; label.textContent=status.message||'Working';
        if(status.state==='completed') {
          bar.className='progress-bar bg-success'; label.textContent=status.result?.target==='peer'?'Backup stored on the paired host.':'Backup stored locally.';
          toast(`${name}: backup completed`);
          if(onComplete) setTimeout(onComplete,900);
          return;
        }
        if(status.state==='failed') {
          bar.className='progress-bar bg-danger'; label.textContent=`Backup failed: ${status.message||'No diagnostic detail.'}`;
          button.disabled=false; button.textContent='Backup now'; toast(status.message||`${name}: backup failed`,'Backup failed'); return;
        }
        setTimeout(update,750);
      } catch(error) {
        bar.className='progress-bar bg-danger'; label.textContent=`Could not read backup status: ${error.message}`;
        button.disabled=false; button.textContent='Backup now';
      }
    };
    update();
  }

  async function loadBackups() {
    if (!hasCap('backup-create')) {
      const [backups, peers] = await Promise.all([request('/backups'), request('/cluster/peers')]);
      const rows=(backups||[]).map(b=>`<tr><td class="mono">${esc(b.vm)}</td><td class="mono">${esc(b.archive)}</td><td>${bytes(b.bytes)}</td><td>${esc(b.modified||'')}</td><td><div class="action-row"><button class="btn btn-sm btn-outline-secondary" data-backup-download="${esc(b.vm)}" data-backup-archive="${esc(b.archive)}">Download</button><button class="btn btn-sm btn-outline-danger" data-backup-delete="${esc(b.vm)}" data-backup-archive="${esc(b.archive)}">Delete</button></div></td></tr>`);
      $('#view').innerHTML=`<div class="mb-3 alert alert-info"><strong>Backup receiver profile.</strong> This node accepts archives from authenticated paired LiteVMM hosts. It does not create, restore, or run virtual machines.</div>${card('Received backups',table(['VM','Archive','Size','Modified',''],rows,'No backups have been received yet.'),`<span class="small text-secondary">${(peers||[]).length} paired host${(peers||[]).length===1?'':'s'}</span>`)}`;
      $$('[data-backup-download]').forEach(b=>b.onclick=()=>downloadFile(`/backups/${encodeURIComponent(b.dataset.backupDownload)}/${encodeURIComponent(b.dataset.backupArchive)}`));
      $$('[data-backup-delete]').forEach(b=>b.onclick=()=>confirmAction('Delete backup',`Delete ${b.dataset.backupArchive}?`,async()=>{await request(`/backups/${encodeURIComponent(b.dataset.backupDelete)}/${encodeURIComponent(b.dataset.backupArchive)}`,{method:'DELETE'});await loadBackups();}));
      return;
    }
    const [backups, schedules, vms, peers] = await Promise.all([request('/backups'), request('/backups/schedules'), request('/vms'), request('/cluster/peers')]);
    state.cache.backupPeers=(peers||[]).filter(usablePeer);
    const vmOptions = vms.map(vm=>`<option value="${esc(vm.name)}">${esc(vm.name)} (${esc(vm.state)})</option>`).join('');
    const rows = backups.map(b=>`<tr><td class="mono">${esc(b.vm)}</td><td class="mono">${esc(b.archive)}</td><td>${bytes(b.bytes)}</td><td><div class="action-row"><a class="btn btn-sm btn-outline-secondary" href="${API}/backups/${encodeURIComponent(b.vm)}/${encodeURIComponent(b.archive)}">Download</a><button class="btn btn-sm btn-outline-danger" data-backup-delete="${esc(b.vm)}" data-backup-archive="${esc(b.archive)}">Delete</button></div></td></tr>`);
    const scheduleRows = schedules.map(s=>`<tr><td class="mono">${esc(s.vm)}</td><td class="mono">${esc(s.cron)}</td><td>${esc(s.label)}</td><td><button class="btn btn-sm btn-outline-danger" data-backup-unschedule="${esc(s.vm)}">Remove</button></td></tr>`);
    $('#view').innerHTML=`<div class="row g-3"><div class="col-xl-8">${card('VM backups',table(['VM','Archive','Size',''],rows,'No backups found.'),'<button class="btn btn-sm btn-primary" id="createBackupBtn">Create backup</button>')}</div><div class="col-xl-4">${card('Schedules',table(['VM','Cron','Label',''],scheduleRows,'No scheduled backups.'),'<button class="btn btn-sm btn-outline-primary" id="scheduleBackupBtn">Schedule backup</button>')}</div></div>`;
    $('#createBackupBtn').onclick=()=>{modal({eyebrow:'VM backup',title:'Create backup',body:`<form id="backupForm"><label class="form-label">Virtual machine</label><select name="name" class="form-select mb-3" required><option value="">Select a VM</option>${vmOptions}</select><label class="form-label">Label</label><input name="label" class="form-control mb-3" value="manual">${backupTargetFields()}<div class="form-check form-switch mt-3"><input name="live" id="liveBackup" class="form-check-input" type="checkbox"><label class="form-check-label" for="liveBackup">Live backup</label></div><div class="form-text">Uses QMP full disk copies while the VM runs. A stopped VM uses an ordinary consistent file copy.</div><button id="vmBackupNowBtn" type="button" class="btn btn-primary mt-3">Backup now</button><div id="vmBackupProgress" class="mt-3 d-none" role="status"><div class="d-flex justify-content-between small mb-1"><span id="vmBackupProgressLabel">Queued</span><span id="vmBackupProgressValue">0%</span></div><div class="progress" style="height:0.5rem"><div id="vmBackupProgressBar" class="progress-bar progress-bar-striped progress-bar-animated" role="progressbar" style="width:0%" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"></div></div></div></form>`});const root=$('#formModal');bindBackupTarget(root);$('#vmBackupNowBtn',root).onclick=async()=>{const fd=new FormData($('#backupForm',root));const name=fd.get('name');if(!name){toast('Select a virtual machine.','Backup not started');return;}let target;try{target=backupTargetData(fd);}catch(error){toast(error.message,'Backup not started');return;}const button=$('#vmBackupNowBtn',root);button.disabled=true;button.textContent='Backup queued';try{const job=await request('/backups/start',{method:'POST',form:{name,...target}});watchBackupJob(job,root,name,async()=>{bootstrap.Modal.getInstance(root)?.hide();await loadBackups();});}catch(error){button.disabled=false;button.textContent='Backup now';$('#vmBackupProgress',root).classList.remove('d-none');$('#vmBackupProgressLabel',root).textContent=`Backup could not start: ${error.message}`;$('#vmBackupProgressBar',root).className='progress-bar bg-danger';toast(error.message,'Backup not started');}};};
    $('#scheduleBackupBtn').onclick=()=>openBackupSchedule(vmOptions);
    $$('[data-backup-delete]').forEach(b=>b.onclick=()=>confirmAction('Delete backup',`Delete ${b.dataset.backupArchive}?`,async()=>{await request(`/backups/${encodeURIComponent(b.dataset.backupDelete)}/${encodeURIComponent(b.dataset.backupArchive)}`,{method:'DELETE'});await loadBackups();}));
    $$('[data-backup-unschedule]').forEach(b=>b.onclick=()=>confirmAction('Remove schedule',`Remove the ${b.dataset.backupUnschedule} schedule?`,async()=>{await request('/backups/unschedule',{method:'DELETE',form:{name:b.dataset.backupUnschedule}});await loadBackups();}));
  }

  async function openVMBackups(name) {
    const [backups, schedules, vm, peers] = await Promise.all([request('/backups'), request('/backups/schedules'), request(`/vms/${encodeURIComponent(name)}`), request('/cluster/peers')]);
    state.cache.backupPeers=(peers||[]).filter(usablePeer);
    // A peer-targeted backup deliberately leaves no source copy after the
    // receiver accepts it. Query each paired host so those archives remain
    // visible from the VM that created them.
    const peerBackups = state.remotePeerId ? [] : await Promise.all(state.cache.backupPeers.map(async peer => {
      try { return {peer, backups:await request('/backups',{peerId:peer.node_id})}; }
      catch(error) { return {peer, error}; }
    }));
    const rows = backups.filter(backup => backup.vm === name).map(backup => `<tr><td class="mono">${esc(backup.archive)}</td><td>${bytes(backup.bytes)}</td><td><div class="action-row"><a class="btn btn-sm btn-outline-secondary" href="${API}/backups/${encodeURIComponent(name)}/${encodeURIComponent(backup.archive)}">Download</a><button class="btn btn-sm btn-outline-primary" data-vm-backup-restore="${esc(backup.archive)}">Restore</button><button class="btn btn-sm btn-outline-danger" data-vm-backup-delete="${esc(backup.archive)}">Delete</button></div></td></tr>`);
    const peerRows = peerBackups.flatMap(({peer,backups:items=[]}) => items.filter(backup=>backup.vm===name).map(backup => `<tr><td>${esc(peer.label||peer.name||peer.node_id)}</td><td class="mono">${esc(backup.archive)}</td><td>${bytes(backup.bytes)}</td><td><button type="button" class="btn btn-sm btn-outline-secondary" data-vm-peer-backup-download="${esc(backup.archive)}" data-vm-peer-id="${esc(peer.node_id)}">Download</button></td></tr>`));
    const peerErrors=peerBackups.filter(item=>item.error).map(item=>esc(item.peer.label||item.peer.name||item.peer.node_id));
    const vmSchedules = schedules.filter(item => item.vm === name);
    const scheduleRows = vmSchedules.map(item=>`<tr><td>${esc(item.label)}</td><td class="mono">${esc(item.cron)}</td><td>${esc(item.keep || 'Unlimited')}</td><td><div>${item.peer_id?'Paired host':'Local folder'}</div><div class="small mono text-break">${esc(item.peer_id ? (state.cache.backupPeers.find(p=>p.node_id===item.peer_id)?.name||item.peer_id) : (item.destination||'/var/lib/vmapi/backups'))}</div><div class="small text-secondary">${item.live?'live copy':'stopped VM'}</div></td><td><button class="btn btn-sm btn-outline-danger" data-vm-backup-unschedule="${esc(item.label)}">Remove</button></td></tr>`);
    modal({eyebrow:'VM backup',title:name,body:`<div class="form-section"><div class="form-section-title">Backup now</div><form id="vmBackupNowForm"><div class="row g-3"><div class="col-md-6"><label class="form-label">Backup name</label><input name="label" class="form-control" value="manual"></div><div class="col-md-6"><label class="form-label">Keep copies</label><input name="keep" type="number" min="1" max="9999" class="form-control" value="3"></div></div>${backupTargetFields()}<div class="form-check form-switch mt-3"><input name="live" id="vmLiveBackup" class="form-check-input" type="checkbox" ${vm.state==='running'?'checked':''}><label class="form-check-label" for="vmLiveBackup">Live backup</label></div><div class="form-text mt-1">Live backup uses QMP full disk copies for running VMs with virtio qcow2 disks.</div><button id="vmBackupNowBtn" type="button" class="btn btn-primary mt-3">Backup now</button><div id="vmBackupProgress" class="mt-3 d-none" role="status"><div class="d-flex justify-content-between small mb-1"><span id="vmBackupProgressLabel">Queued</span><span id="vmBackupProgressValue">0%</span></div><div class="progress" style="height:0.5rem"><div id="vmBackupProgressBar" class="progress-bar progress-bar-striped progress-bar-animated" role="progressbar" style="width:0%" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"></div></div><div class="form-text mt-1">Progress reflects backup phases; disk-copy byte progress is not exposed by QMP.</div></div></form></div><div class="form-section"><div class="form-section-title d-flex justify-content-between align-items-center">Scheduled backup plan <button id="vmBackupScheduleBtn" type="button" class="btn btn-sm btn-outline-primary">Configure plan</button></div>${table(['Tier','Schedule','Keep','Destination',''],scheduleRows,'No scheduled backup plan for this VM.')}</div><div class="form-section"><div class="form-section-title">Local backups</div>${table(['Archive','Size',''],rows,'No local backups for this VM.')}</div><div class="form-section"><div class="form-section-title">Backups on paired hosts</div>${table(['Host','Archive','Size',''],peerRows,'No paired-host backups found.')}${peerErrors.length?`<div class="form-text text-warning mt-2">Could not query: ${peerErrors.join(', ')}.</div>`:''}</div>`});
    bindBackupTarget($('#formModal'));
    $('#vmBackupNowBtn', $('#formModal')).onclick=async()=>{const root=$('#formModal');const button=$('#vmBackupNowBtn',root);const form=$('#vmBackupNowForm',root);let data;try{data=backupTargetData(new FormData(form));}catch(error){toast(error.message,'Backup not started');return;}button.disabled=true;button.textContent='Backup queued';try{const job=await request('/backups/start',{method:'POST',form:{name,...data}});watchBackupJob(job,root,name,()=>openVMBackups(name));}catch(error){$('#vmBackupProgress',root).classList.remove('d-none');$('#vmBackupProgressLabel',root).textContent=`Backup could not start: ${error.message}`;$('#vmBackupProgressBar',root).className='progress-bar bg-danger';button.disabled=false;button.textContent='Backup now';toast(error.message,'Backup not started');}};
    $$('[data-vm-peer-backup-download]', $('#formModal')).forEach(button=>button.onclick=()=>downloadFile(`/backups/${encodeURIComponent(name)}/${encodeURIComponent(button.dataset.vmPeerBackupDownload)}`,button.dataset.vmPeerId));
    $$('[data-vm-backup-delete]', $('#formModal')).forEach(button=>button.onclick=()=>confirmAction('Delete backup',`Delete ${button.dataset.vmBackupDelete}?`,async()=>{await request(`/backups/${encodeURIComponent(name)}/${encodeURIComponent(button.dataset.vmBackupDelete)}`,{method:'DELETE'});await openVMBackups(name);}));
    $$('[data-vm-backup-restore]', $('#formModal')).forEach(button=>button.onclick=()=>confirmAction('Restore backup',`Restore ${button.dataset.vmBackupRestore}? The VM must not already exist.`,async()=>{await request('/backups/restore',{method:'POST',form:{name,archive:button.dataset.vmBackupRestore}});toast(`${name}: restore completed`);await openVMBackups(name);},false));
    $$('[data-vm-backup-unschedule]', $('#formModal')).forEach(button=>button.onclick=()=>confirmAction('Remove schedule',`Remove the ${button.dataset.vmBackupUnschedule} policy?`,async()=>{await request('/backups/unschedule',{method:'DELETE',form:{name,label:button.dataset.vmBackupUnschedule}});await openVMBackups(name);}));
    $('#vmBackupScheduleBtn', $('#formModal')).onclick=()=>openVMBackupSchedule(name);
  }

  function openVMBackupSchedule(name) {
    modal({eyebrow:'VM backup',title:`Backup plan: ${name}`,submitText:'Save backup plan',size:'lg',body:`<form id="scheduleForm"><div class="form-section"><div class="form-section-title">Retention tiers</div><div class="row g-3"><div class="col-md-4"><div class="form-check form-switch mb-2"><input name="daily" id="dailyTier" class="form-check-input" type="checkbox" checked><label class="form-check-label" for="dailyTier">Daily backups</label></div><label class="form-label">Keep daily copies</label><input name="daily_keep" type="number" min="1" max="9999" value="7" class="form-control"></div><div class="col-md-4"><div class="form-check form-switch mb-2"><input name="weekly" id="weeklyTier" class="form-check-input" type="checkbox" checked><label class="form-check-label" for="weeklyTier">Weekly backups</label></div><label class="form-label">Keep weekly copies</label><input name="weekly_keep" type="number" min="1" max="9999" value="4" class="form-control"></div><div class="col-md-4"><div class="form-check form-switch mb-2"><input name="monthly" id="monthlyTier" class="form-check-input" type="checkbox" checked><label class="form-check-label" for="monthlyTier">Monthly backups</label></div><label class="form-label">Keep monthly copies</label><input name="monthly_keep" type="number" min="1" max="9999" value="12" class="form-control"></div></div></div><div class="form-section"><div class="form-section-title">Schedule</div><div class="row g-3"><div class="col-md-4"><label class="form-label">Time</label><input name="time" type="time" class="form-control" value="02:00"></div><div class="col-md-4"><label class="form-label">Weekly day</label><select name="weekday" class="form-select"><option value="0">Sunday</option><option value="1">Monday</option><option value="2">Tuesday</option><option value="3">Wednesday</option><option value="4">Thursday</option><option value="5">Friday</option><option value="6">Saturday</option></select></div><div class="col-md-4"><label class="form-label">Monthly day</label><input name="monthday" type="number" min="1" max="28" value="1" class="form-control"></div></div></div><div class="form-section"><div class="form-section-title">Destination</div>${backupTargetFields()}<div class="form-check form-switch mt-3"><input name="live" id="scheduleLiveBackup" class="form-check-input" type="checkbox"><label class="form-check-label" for="scheduleLiveBackup">Live backup</label></div></div></form>`,onSubmit:async(el,m)=>{const form=$('#scheduleForm',el);const fd=new FormData(form);const target=backupTargetData(fd);const [hour,minute]=(fd.get('time')||'02:00').split(':');const base={name,destination:target.destination,peer_id:target.peer_id,live:target.live};const tiers=[['daily','daily_keep',`${Number(minute)} ${Number(hour)} * * *`],['weekly','weekly_keep',`${Number(minute)} ${Number(hour)} * * ${fd.get('weekday')}`],['monthly','monthly_keep',`${Number(minute)} ${Number(hour)} ${fd.get('monthday')} * *`]];for(const [label,keepField,cron] of tiers){if(fd.has(label))await request('/backups/schedule',{method:'POST',form:{...base,label,keep:fd.get(keepField),cron}});}m.hide();toast(`${name}: backup plan saved`);await openVMBackups(name);}});
    bindBackupTarget($('#formModal'));
  }

  function backupTargetFields() {
    const peers=state.cache.backupPeers||[];
    return `<div class="row g-3 mt-1"><div class="col-md-4"><label class="form-label">Store backup</label><select name="target" class="form-select"><option value="local">Local or mounted folder</option><option value="peer" ${peers.length?'':'disabled'}>Authenticated paired host</option></select></div><div class="col-md-8" data-backup-local><label class="form-label">Storage folder</label><input name="destination" class="form-control mono" value="/var/lib/vmapi/backups"></div><div class="col-md-8 d-none" data-backup-peer><label class="form-label">Destination peer</label><select name="peer_id" class="form-select"><option value="">Select a paired host</option>${peers.map(p=>`<option value="${esc(p.node_id)}">${esc(p.label||p.name||p.node_id)}</option>`).join('')}</select></div></div><div class="form-text mt-2" data-backup-target-note>Local folders can be mounted network shares.</div>`;
  }
  function bindBackupTarget(root) {
    const target=$('select[name="target"]',root); const sync=()=>{const peer=target.value==='peer';$('[data-backup-peer]',root)?.classList.toggle('d-none',!peer);$('[data-backup-local]',root)?.classList.toggle('d-none',peer);$('[data-backup-target-note]',root).textContent=peer?'The archive is streamed over the signed peer API and retained on the destination host only.':'Local folders can be mounted network shares.';};target.onchange=sync;sync();
  }
  function backupTargetData(formData) {
    const data=Object.fromEntries(formData.entries());
    if(data.target==='peer'&&!data.peer_id)throw new Error('Select a destination peer.');
    return {label:data.label,keep:data.keep,live:formData.has('live')?'true':'false',frequency:data.frequency,cron:data.cron,time:data.time,weekday:data.weekday,monthday:data.monthday,destination:data.target==='local'?data.destination:'',peer_id:data.target==='peer'?data.peer_id:''};
  }

  function openBackupSchedule(vmOptions) {
    modal({eyebrow:'VM backup',title:'Schedule backup',submitText:'Schedule',size:'sm',body:`<form id="scheduleForm"><label class="form-label">Virtual machine</label><select name="name" class="form-select mb-3" required><option value="">Select a VM</option>${vmOptions}</select><div class="row g-3"><div class="col-7"><label class="form-label">Frequency</label><select name="frequency" class="form-select"><option value="daily">Daily</option><option value="weekly">Weekly</option><option value="monthly">Monthly</option><option value="custom">Custom cron</option></select></div><div class="col-5"><label class="form-label">Time</label><input name="time" type="time" class="form-control" value="02:00"></div><div class="col-12" id="scheduleWeekday"><label class="form-label">Day of week</label><select name="weekday" class="form-select"><option value="0">Sunday</option><option value="1">Monday</option><option value="2">Tuesday</option><option value="3">Wednesday</option><option value="4">Thursday</option><option value="5">Friday</option><option value="6">Saturday</option></select></div><div class="col-12 d-none" id="scheduleMonthday"><label class="form-label">Day of month</label><input name="monthday" type="number" min="1" max="28" value="1" class="form-control"></div><div class="col-12 d-none" id="scheduleCustom"><label class="form-label">Cron expression</label><input name="cron" class="form-control mono" placeholder="0 2 * * *"></div></div><label class="form-label mt-3">Label</label><input name="label" class="form-control" value="scheduled"></form>`,onSubmit:async(el,m)=>{const form=$('#scheduleForm',el);const fd=new FormData(form);const o=Object.fromEntries(fd.entries());if(!o.name)throw new Error('Select a virtual machine.');if(o.frequency!=='custom'){const [hour,minute]=o.time.split(':');o.cron=o.frequency==='daily'?`${Number(minute)} ${Number(hour)} * * *`:o.frequency==='weekly'?`${Number(minute)} ${Number(hour)} * * ${o.weekday}`:`${Number(minute)} ${Number(hour)} ${o.monthday} * *`;}await request('/backups/schedule',{method:'POST',form:o});m.hide();toast(`${o.name}: backup scheduled`);await loadBackups();}});
    const form=$('#scheduleForm', $('#formModal')); const frequency=$('select[name="frequency"]',form); const sync=()=>{const custom=frequency.value==='custom';$('#scheduleWeekday',form).classList.toggle('d-none',frequency.value!=='weekly');$('#scheduleMonthday',form).classList.toggle('d-none',frequency.value!=='monthly');$('#scheduleCustom',form).classList.toggle('d-none',!custom);$('input[name="time"]',form).disabled=custom;}; frequency.onchange=sync; sync();
  }

  async function loadAdmin() {
    const status=await request('/admin');
    const svc=state.activeService||state.service||{};
    const tls=status.tls_enabled===true;
    const certActions=status.certbot_available ? `<div class="d-flex flex-wrap gap-2"><button id="configureCertBtn" class="btn btn-primary">${tls?'Replace certificate':'Configure Certbot'}</button>${tls?'<button id="renewCertBtn" class="btn btn-outline-primary">Renew certificate</button><button id="disableTlsBtn" class="btn btn-outline-danger">Disable HTTPS</button>':''}</div>` : '<div class="alert alert-warning mb-0">Certbot is not installed on this host. Re-run <span class="mono">install.sh --certbot</span> to enable certificate management. Containerized backup receivers normally terminate TLS at a reverse proxy.</div>';
    $('#view').innerHTML=`<div class="row g-3 mb-3"><div class="col-xl-6">${card('Installation',systemDl([['Profile',svc.profile||status.profile],['API version',svc.version],['Management port',svc.port||status.port],['Transport',tls?'HTTPS':'HTTP'],['Capabilities',(svc.capabilities||[]).join(', ')]]))}</div><div class="col-xl-6">${card('TLS certificate',systemDl([['Certbot',status.certbot_available?'Installed':'Not installed'],['Enabled',tls?'Yes':'No'],['Domain',status.domain||''],['Expires',status.expires||''],['Certificate',status.certificate||'',true]]))}</div></div>${card('Certificate management',`<div class="small text-secondary mb-3">Certbot uses the HTTP-01 standalone challenge on TCP port 80. DNS for the requested name must resolve to this host and port 80 must be reachable while a certificate is issued or renewed.</div>${certActions}`)}`;
    $('#configureCertBtn')?.addEventListener('click',()=>modal({eyebrow:'Administration',title:'Configure Certbot certificate',submitText:'Issue certificate',body:`<form id="certForm"><label class="form-label">DNS name</label><input name="domain" class="form-control mono mb-3" value="${esc(status.domain||'')}" placeholder="litevmm.example.com" required><label class="form-label">ACME email</label><input name="email" type="email" class="form-control" required><div class="form-text mt-3">Successful issuance switches the configured LiteVMM management port to HTTPS using the new certificate.</div></form>`,onSubmit:async(el,m)=>{const fd=new FormData($('#certForm',el));await request('/admin/certificates',{method:'POST',form:{domain:fd.get('domain'),email:fd.get('email')}});m.hide();toast('Certificate configured. Reload using HTTPS if the browser connection changes.');await loadAdmin();}}));
    $('#renewCertBtn')?.addEventListener('click',async()=>{await request('/admin/certificates/renew',{method:'POST',form:{}});toast('Certificate renewal completed');await loadAdmin();});
    $('#disableTlsBtn')?.addEventListener('click',()=>confirmAction('Disable HTTPS','Return the LiteVMM management endpoint to HTTP?',async()=>{await request('/admin/certificates',{method:'DELETE'});toast('HTTPS disabled');await loadAdmin();},false));
  }

  const routes = {
    dashboard: {title:'Overview', eyebrow:'LiteVMM', load:loadDashboard},
    system: {title:'System information', eyebrow:'Host diagnostics', load:loadSystemInfo},
    backups: {title:'Backups', eyebrow:'Archive management', load:loadBackups},
    admin: {title:'Administration', eyebrow:'LiteVMM configuration', load:loadAdmin},
    vms: {title:'Virtual machines', eyebrow:'QEMU / KVM', load:loadVMs},
    containers: {title:'Containers', eyebrow:'Docker', load:loadContainers},
    compose: {title:'Compose', eyebrow:'Docker', load:loadCompose},
    networks: {title:'Networks', eyebrow:'Host + Docker', load:loadNetworks},
    cluster: {title:'Cluster', eyebrow:'Trusted peers', load:loadCluster},
  };

  async function renderRoute() {
    stopPoller('dashboard');
    stopPoller('detail');
    const hash = (location.hash || '#dashboard').slice(1);
    const [routeName, query] = hash.split('?', 2);
    const requestedPeer = new URLSearchParams(query || '').get('peer') || '';
    state.remotePeerId = /^[a-f0-9]{32}$/i.test(requestedPeer) ? requestedPeer.toLowerCase() : '';
    state.route = routeName;
    if (!routes[state.route]) state.route='dashboard';
    if (state.route === 'cluster') state.remotePeerId='';
    try { state.activeService=state.remotePeerId ? await request('/') : state.service; } catch { state.activeService=state.service; }
    updateCapabilityUI();
    if (!routeAllowed(state.route)) state.route='dashboard';
    const r=routes[state.route];
    $('#pageTitle').textContent=state.remotePeerId ? `Remote host · ${r.title}` : r.title;
    $('#pageEyebrow').textContent=state.remotePeerId ? `Paired node ${state.remotePeerId.slice(0,12)}…` : r.eyebrow;
    renderHostSelector();
    $$('[data-route]').forEach(a=>{a.classList.toggle('active',a.dataset.route===state.route);a.href=a.dataset.route==='cluster'?'#cluster':`#${a.dataset.route}${state.remotePeerId?`?peer=${encodeURIComponent(state.remotePeerId)}`:''}`;});
    $('#view').innerHTML=`<div class="d-flex justify-content-center align-items-center py-5"><div class="spinner-border spinner-border-sm me-2"></div><span class="text-secondary">Loading ${esc(r.title.toLowerCase())}…</span></div>`;
    try { await r.load(); setConnection(true,state.service?.user); }
    catch(e){ setConnection(false,state.service?.user); $('#view').innerHTML=`<div class="alert alert-danger"><strong>Unable to load this view.</strong><div class="mt-1">${esc(e.message)}</div></div>`; }
  }

  async function init() {
    const saved=localStorage.getItem('vmapi-theme'); if(saved) document.documentElement.dataset.bsTheme=saved;
    $('#themeToggle').onclick=()=>{const next=document.documentElement.dataset.bsTheme==='dark'?'light':'dark';document.documentElement.dataset.bsTheme=next;localStorage.setItem('vmapi-theme',next);};
    $('#refreshBtn').onclick=()=>renderRoute();
    $('#hostSelector').onchange=event=>{ location.hash=hostRouteHash(state.route, event.target.value); };
    window.addEventListener('hashchange',renderRoute);
    $('#formModal').addEventListener('hidden.bs.modal',()=>stopPoller('detail'));
    try { state.service=await request('/'); state.activeService=state.service; updateCapabilityUI(); setConnection(true,state.service?.user); }
    catch(e){ setConnection(false); }
    await loadHostCatalog();
    await renderRoute();
  }

  init();
})();
