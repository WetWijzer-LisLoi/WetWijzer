// The server advertises its actual stream supervisor through this header.
// The fallback ceiling keeps cached/rolling-deploy responses from older
// servers safe too; keep it aligned with ChatbotController's maximum.
export const CHATBOT_STREAM_TIMEOUT_HEADER = 'X-Chatbot-Stream-Hard-Timeout-Seconds'
export const SERVER_STREAM_HARD_TIMEOUT_CEILING_MS = 175_000
export const BROWSER_STREAM_TIMEOUT_GRACE_MS = 15_000

export function browserStreamTimeoutMs(serverTimeoutSeconds = null) {
  const parsedSeconds = Number.parseFloat(serverTimeoutSeconds)
  const supervisorMs = Number.isFinite(parsedSeconds) && parsedSeconds > 0
    ? Math.ceil(parsedSeconds * 1000)
    : SERVER_STREAM_HARD_TIMEOUT_CEILING_MS

  return supervisorMs + BROWSER_STREAM_TIMEOUT_GRACE_MS
}
