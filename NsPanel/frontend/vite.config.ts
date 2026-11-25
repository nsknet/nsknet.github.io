/// <reference types="vitest/config" />
import { execSync } from 'node:child_process';
import { fileURLToPath, URL } from 'node:url';

import tailwindcss from '@tailwindcss/vite';
import vue from '@vitejs/plugin-vue';
import { defineConfig, type Plugin } from 'vite';

import pkg from './package.json' with { type: 'json' };

// The built SPA is committed to ../static/dist so a VPS can `git clone` and run
// without Node installed. `npm run dev` proxies the API to a locally running panel.
const backend = process.env.NSPANEL_BACKEND ?? 'http://127.0.0.1:7777';

function git(args: string): string {
  try {
    return execSync(`git ${args}`, { cwd: fileURLToPath(new URL('.', import.meta.url)) })
      .toString()
      .trim();
  } catch {
    return '';
  }
}

// The last commit that touched frontend/: the backend compares it with its own
// view of the same thing to tell when static/dist is older than the source.
const frontendCommit = git('log -1 --format=%H -- .');

/** Writes static/dist/version.json next to the bundle. */
function versionFile(): Plugin {
  return {
    name: 'nspanel-version-file',
    apply: 'build',
    generateBundle() {
      this.emitFile({
        type: 'asset',
        fileName: 'version.json',
        source: `${JSON.stringify({ version: pkg.version, frontend_commit: frontendCommit }, null, 2)}\n`,
      });
    },
  };
}

export default defineConfig({
  base: './',
  plugins: [vue(), tailwindcss(), versionFile()],
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
    __FRONTEND_COMMIT__: JSON.stringify(frontendCommit),
  },
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  build: {
    outDir: '../static/dist',
    emptyOutDir: true,
    rollupOptions: {
      output: { inlineDynamicImports: true },
    },
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.ts'],
  },
  server: {
    port: 7778,
    proxy: Object.fromEntries(
      ['/api', '/stream', '/healthz', '/logo'].map((path) => [
        path,
        // Keep the Host header: the panel refuses POSTs whose Origin differs from Host.
        { target: backend, changeOrigin: false },
      ]),
    ),
  },
});
