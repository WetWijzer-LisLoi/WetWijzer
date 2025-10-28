/**
 * ConversationCrypto - Zero-Knowledge Client-Side Encryption
 *
 * Uses the Web Crypto API (SubtleCrypto) to encrypt/decrypt conversation
 * data entirely in the browser. The server never sees plaintext or keys.
 *
 * Architecture:
 *   masterKey (AES-256-GCM)  → encrypts conversation payloads
 *   wrappingKey (PBKDF2)     → encrypts the masterKey for storage
 *   password + salt → wrappingKey (derived, never stored)
 *
 * The wrapped (encrypted) masterKey is stored on the server.
 * On login, the user's password re-derives the wrappingKey to unwrap it.
 */

const PBKDF2_ITERATIONS = 600_000
const AES_KEY_LENGTH = 256
const IV_LENGTH = 12 // 96-bit IV for AES-GCM

export const ConversationCrypto = {
  /**
   * Check if Web Crypto API is available
   */
  isAvailable() {
    return !!(window.crypto && window.crypto.subtle)
  },

  /**
   * Generate a random AES-256-GCM master key
   * @returns {Promise<CryptoKey>}
   */
  async generateMasterKey() {
    return crypto.subtle.generateKey(
      { name: 'AES-GCM', length: AES_KEY_LENGTH },
      true, // extractable (needed for wrapping)
      ['encrypt', 'decrypt']
    )
  },

  /**
   * Generate a unique salt for key derivation (one per user)
   * @returns {string} base64-encoded salt
   */
  generateSalt() {
    const salt = crypto.getRandomValues(new Uint8Array(32))
    return this._toBase64(salt)
  },

  /**
   * Derive a wrapping key from password + salt using PBKDF2
   * @param {string} password - user's password
   * @param {string} saltBase64 - base64-encoded salt
   * @returns {Promise<CryptoKey>}
   */
  async deriveWrappingKey(password, saltBase64) {
    const encoder = new TextEncoder()
    const salt = this._fromBase64(saltBase64)

    const keyMaterial = await crypto.subtle.importKey(
      'raw',
      encoder.encode(password),
      'PBKDF2',
      false,
      ['wrapKey', 'unwrapKey']
    )

    return crypto.subtle.deriveKey(
      {
        name: 'PBKDF2',
        salt: salt,
        iterations: PBKDF2_ITERATIONS,
        hash: 'SHA-256'
      },
      keyMaterial,
      { name: 'AES-GCM', length: AES_KEY_LENGTH },
      false,
      ['wrapKey', 'unwrapKey']
    )
  },

  /**
   * Wrap (encrypt) the master key with the wrapping key
   * @param {CryptoKey} masterKey
   * @param {CryptoKey} wrappingKey
   * @returns {Promise<string>} base64-encoded wrapped key (iv + ciphertext)
   */
  async wrapMasterKey(masterKey, wrappingKey) {
    const iv = crypto.getRandomValues(new Uint8Array(IV_LENGTH))
    const wrapped = await crypto.subtle.wrapKey(
      'raw',
      masterKey,
      wrappingKey,
      { name: 'AES-GCM', iv }
    )

    // Prepend IV to wrapped key
    const combined = new Uint8Array(iv.length + new Uint8Array(wrapped).length)
    combined.set(iv)
    combined.set(new Uint8Array(wrapped), iv.length)
    return this._toBase64(combined)
  },

  /**
   * Unwrap (decrypt) the master key with the wrapping key
   * @param {string} wrappedBase64 - base64-encoded wrapped key
   * @param {CryptoKey} wrappingKey
   * @returns {Promise<CryptoKey>}
   */
  async unwrapMasterKey(wrappedBase64, wrappingKey) {
    const combined = this._fromBase64(wrappedBase64)
    const iv = combined.slice(0, IV_LENGTH)
    const wrapped = combined.slice(IV_LENGTH)

    return crypto.subtle.unwrapKey(
      'raw',
      wrapped,
      wrappingKey,
      { name: 'AES-GCM', iv },
      { name: 'AES-GCM', length: AES_KEY_LENGTH },
      false, // not extractable once unwrapped
      ['encrypt', 'decrypt']
    )
  },

  /**
   * Encrypt a payload (conversation data) with the master key
   * @param {any} data - JSON-serializable data
   * @param {CryptoKey} masterKey
   * @returns {Promise<string>} base64-encoded ciphertext (iv + encrypted)
   */
  async encryptPayload(data, masterKey) {
    const iv = crypto.getRandomValues(new Uint8Array(IV_LENGTH))
    const encoder = new TextEncoder()
    const plaintext = encoder.encode(JSON.stringify(data))

    const encrypted = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv },
      masterKey,
      plaintext
    )

    // Prepend IV to ciphertext
    const combined = new Uint8Array(iv.length + new Uint8Array(encrypted).length)
    combined.set(iv)
    combined.set(new Uint8Array(encrypted), iv.length)
    return this._toBase64(combined)
  },

  /**
   * Decrypt a payload with the master key
   * @param {string} ciphertextBase64 - base64-encoded ciphertext
   * @param {CryptoKey} masterKey
   * @returns {Promise<any>} decrypted JSON data
   */
  async decryptPayload(ciphertextBase64, masterKey) {
    if (!ciphertextBase64) return null

    const combined = this._fromBase64(ciphertextBase64)
    const iv = combined.slice(0, IV_LENGTH)
    const encrypted = combined.slice(IV_LENGTH)

    const decrypted = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv },
      masterKey,
      encrypted
    )

    return JSON.parse(new TextDecoder().decode(decrypted))
  },

  /**
   * Try to decrypt, returning null on failure (wrong key, corrupt data, legacy plaintext)
   * @param {string} ciphertextBase64
   * @param {CryptoKey} masterKey
   * @returns {Promise<any|null>}
   */
  async tryDecrypt(ciphertextBase64, masterKey) {
    try {
      if (!ciphertextBase64 || !masterKey) return null
      return await this.decryptPayload(ciphertextBase64, masterKey)
    } catch {
      // Could be legacy plaintext, corrupted, or wrong key
      return null
    }
  },

  // ── Base64 helpers (URL-safe) ──

  _toBase64(uint8Array) {
    let binary = ''
    for (let i = 0; i < uint8Array.length; i++) {
      binary += String.fromCharCode(uint8Array[i])
    }
    return btoa(binary)
  },

  _fromBase64(base64) {
    const binary = atob(base64)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i)
    }
    return bytes
  }
}
