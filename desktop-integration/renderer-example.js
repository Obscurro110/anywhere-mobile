/**
 * Anywhere Desktop — renderer side relay helper (example)
 * =======================================================
 * Put this in the chat window renderer, e.g. render/window/src/relay.js,
 * and call `initRelayWindow()` once when the window mounts.
 *
 * The main-process bridge (`main/relay/index.js`) forwards phone messages as
 * `window:event-bus` events with event === 'relay:incoming'. We listen via
 * `window.api.onWindowEvent` (the same channel the desktop already uses).
 *
 * Sending back to the phone can be done two ways:
 *   1) window.electron.ipcRenderer.invoke('relay:sendChat', { text, to })
 *   2) (recommended) the wrapper below: relaySendChat(text)
 */

// --- low level ipc ---
function relayInvoke(channel, payload) {
  // window.electron.ipcRenderer is exposed by preload/window_preload.js
  return window.electron?.ipcRenderer?.invoke(channel, payload)
}

export async function relayStatus() {
  return relayInvoke('relay:status')
}

export async function relaySendChat(text, to = '*') {
  return relayInvoke('relay:sendChat', { text, to })
}

export async function relaySendNotification(title, body, to = '*') {
  return relayInvoke('relay:sendNotification', { title, body, to })
}

export async function relaySendFile(filePath, to = '*') {
  return relayInvoke('relay:sendFile', { path: filePath, to })
}

/**
 * Wire incoming phone traffic into the desktop UI / AI pipeline.
 *
 * @param {object} handlers
 * @param {(msg)=>void}  handlers.onChat        - a phone user message { text, from, ts, id }
 * @param {(n)=>void}    handlers.onNotification - a notification { title, body }
 * @param {(f)=>void}    handlers.onFile        - a file offer { file: {id,name,size,mime} }
 * @param {(s)=>void}    handlers.onStatus      - { connected, deviceId }
 * @param {(p)=>void}    handlers.onPresence    - { peers: [...] }
 */
export function initRelayWindow(handlers = {}) {
  if (!window.api?.onWindowEvent) {
    console.warn('[relay] window.api.onWindowEvent unavailable')
    return () => {}
  }

  const listener = (envelope) => {
    const { event, payload } = envelope || {}
    switch (event) {
      case 'relay:incoming':
        if (payload?.kind === 'chat') handlers.onChat?.(payload)
        else if (payload?.kind === 'notification') handlers.onNotification?.(payload)
        else if (payload?.kind === 'file') handlers.onFile?.(payload)
        break
      case 'relay:status':
        handlers.onStatus?.(payload)
        break
      case 'relay:presence':
        handlers.onPresence?.(payload)
        break
      default:
        break
    }
  }

  window.api.onWindowEvent(listener)
  return () => {
    // onWindowEvent has no off(); guard with a flag if you re-mount
  }
}

/* ------------------------------------------------------------------
 * Example wiring (pseudo — adapt to your Vue component):
 * ------------------------------------------------------------------
 *
 * import { initRelayWindow, relaySendChat } from './relay'
 *
 * onMounted(() => {
 *   initRelayWindow({
 *     onChat: async (msg) => {
 *       // 1) show the phone message in the active conversation
 *       appendIncomingMessage({ role: 'user', text: msg.text, source: 'phone' })
 *
 *       // 2) run your existing AI pipeline here. When the assistant
 *       //    finishes streaming, send the final text back to the phone:
 *       //    (replace this with your real chat runner)
 *       const reply = await runAgentOnce(msg.text)
 *       await relaySendChat(reply)
 *     },
 *     onNotification: (n) => toast(`${n.title}: ${n.body}`),
 *     onFile: (f) => addIncomingFileToList(f.file),
 *     onStatus: (s) => setRelayDot(s.connected),
 *     onPresence: (p) => setOnlineDevices(p.peers),
 *   })
 * })
 */
