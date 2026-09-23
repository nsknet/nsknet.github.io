import { fileURLToPath, URL } from 'node:url';

import tailwindcss from '@tailwindcss/vite';
import vue from '@vitejs/plugin-vue';
import { defineConfig } from 'vite';

// The built SPA is committed to ../static/dist so a VPS can `git clone` and run
// without Node installed. `npm run dev` proxies the API to a locally running panel.
const backend = process.env.NSPANEL_BACKEND ?? 'http://127.0.0.1:7777';

export default defineConfig({
  base: './',
  plugins: [vue(), tailwindcss()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  build: {
    outDir: '../static/dist',
    emptyOutDir: true,
  },
  server: {
    port: 7778,
    proxy: Object.fromEntries(
      ['/api', '/stream', '/logout', '/logo'].map((path) => [
        path,
        { target: backend, changeOrigin: true },
      ]),
    ),
  },
});
