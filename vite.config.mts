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
        api: 'modern-compiler',
        silenceDeprecations: ['import']
      }
    }
  },
  // RubyPlugin owns entry discovery and the production manifest. Registering
  // the same input here as well makes Vite 8 emit a self-referential import.
  resolve: {
    alias: {
      '@': resolve(__dirname, 'app/javascript')
    }
  },
  plugins: [
    RubyPlugin(),
  ],
})
