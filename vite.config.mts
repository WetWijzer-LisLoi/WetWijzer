import { defineConfig } from 'vite'
import RubyPlugin from 'vite-plugin-ruby'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

export default defineConfig({
  css: {
    preprocessorOptions: {
      scss: {
        api: 'modern-compiler' // or "modern"
      }
    }
  },
  // Ensure Rails can locate assets via manifest.json
  build: {
    manifest: true,
    rollupOptions: {
      input: {
        application: 'app/javascript/entrypoints/application.js',
      },
    },
  },
  resolve: {
    alias: {
      '@': resolve(__dirname, 'app/javascript')
    }
  },
  plugins: [
    RubyPlugin(),
    ],
})
