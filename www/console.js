(() => {
  // noVNC session page. Query parameters identify a short-lived, server-created console token.
  // The browser only connects through the reverse-proxied WebSocket path; it never reaches VNC directly.
  'use strict';

  const params = new URLSearchParams(location.search);
  const vm = params.get('vm') || '';
  const path = params.get('path') || '';
  const token = params.get('token') || '';
  const title = document.querySelector('#consoleTitle');
  const state = document.querySelector('#consoleState');
  const screen = document.querySelector('#consoleScreen');
  const pasteClipboard = document.querySelector('#pasteClipboard');
  const ctrlAltDel = document.querySelector('#sendCtrlAltDel');
  const disconnect = document.querySelector('#disconnectConsole');
  const reconnect = document.querySelector('#reconnectConsole');
  let rfb = null;
  let timer = null;

  title.textContent = vm || 'Console';

  function setState(message, tone = 'secondary') {
    state.textContent = message;
    state.className = `console-state small text-${tone}`;
  }

  function sessionRequest(method, body) {
    return fetch(`/api/vms/${encodeURIComponent(vm)}/console/session`, {
      method,
      credentials: 'same-origin',
      keepalive: method === 'DELETE',
      headers: { 'Accept': 'application/json', 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: body || 'heartbeat=1'
    });
  }

  function touch() {
    return sessionRequest('PATCH', 'heartbeat=1')
      .then(r => { if (!r.ok) throw new Error(String(r.status)); setState('Session active', 'success'); })
      .catch(() => setState('Session heartbeat failed', 'warning'));
  }

  function disconnectRfb() {
    if (!rfb) return;
    rfb.disconnect();
    rfb = null;
  }

  async function connect() {
    if (!vm || !path || !token) { setState('Missing console session', 'danger'); return; }
    disconnectRfb();
    screen.innerHTML = '';
    setState('Connecting...', 'secondary');
    try {
      const mod = await import('/novnc/core/rfb.js');
      const RFB = mod.default;
      const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
      const wsPath = path.startsWith('/') ? path.slice(1) : path;
      const wsUrl = new URL(`${scheme}://${location.host}/${wsPath}`);
      wsUrl.searchParams.set('token', token);
      rfb = new RFB(screen, wsUrl.href, { credentials: {} });
      rfb.scaleViewport = true;
      rfb.resizeSession = false;
      rfb.viewOnly = false;
      rfb.focusOnClick = true;
      rfb.addEventListener('connect', () => { setState('Connected', 'success'); screen.focus(); });
      rfb.addEventListener('disconnect', event => setState(event.detail?.clean ? 'Disconnected' : 'Disconnected unexpectedly', event.detail?.clean ? 'secondary' : 'warning'));
      rfb.addEventListener('credentialsrequired', () => setState('VNC password required', 'warning'));
      await touch();
      clearInterval(timer);
      timer = setInterval(touch, 30000);
    } catch (error) {
      setState(`Console failed: ${error.message}`, 'danger');
    }
  }

  async function pasteIntoVm() {
    if (!rfb) { setState('Console is not connected', 'warning'); return; }
    let text = '';
    try { text = await navigator.clipboard.readText(); } catch { text = window.prompt('Paste text into the VM:') || ''; }
    if (!text) return;
    rfb.clipboardPasteFrom(text);
    setState('Text pasted into VM', 'success');
    screen.focus();
  }

  pasteClipboard.addEventListener('click', pasteIntoVm);
  ctrlAltDel.addEventListener('click', () => rfb?.sendCtrlAltDel());
  disconnect.addEventListener('click', () => { disconnectRfb(); sessionRequest('DELETE', 'close=1').catch(() => {}); clearInterval(timer); setState('Disconnected', 'secondary'); });
  reconnect.addEventListener('click', connect);
  window.addEventListener('pagehide', () => {
    clearInterval(timer);
    disconnectRfb();
    if (vm) sessionRequest('DELETE', 'close=1').catch(() => {});
  });
  connect();
})();
