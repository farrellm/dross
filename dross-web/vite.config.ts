import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The dev server proxies the API to the bot's web server (server.go), so
// `make web-dev` and `dross-bot web` are the two halves of the dev loop.
const api = process.env.DROSS_WEB_API ?? 'http://127.0.0.1:8181'

export default defineConfig({
  plugins: [react()],
  server: {
    // Reachable from the phone over the tailnet, like the bot itself.
    host: true,
    proxy: { '/api': { target: api, changeOrigin: true } },
  },
  build: { outDir: 'dist', sourcemap: true },
})
