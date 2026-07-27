import { resolve } from 'node:path';
import { defineConfig, externalizeDepsPlugin } from 'electron-vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

const alias = {
  '@shared': resolve(__dirname, 'src/shared'),
  '@domain': resolve(__dirname, 'src/domain'),
  '@main': resolve(__dirname, 'src/main'),
  '@renderer': resolve(__dirname, 'src/renderer/src'),
};

export default defineConfig({
  main: {
    // better-sqlite3 is a native addon and must stay external so the rebuilt
    // .node binary is loaded at runtime. electron-store is ESM-only, so it is
    // deliberately *not* externalised — bundling it lets the CommonJS main
    // process use it without a dynamic import dance.
    plugins: [externalizeDepsPlugin({ exclude: ['electron-store'] })],
    resolve: { alias },
    build: {
      outDir: 'out/main',
      rollupOptions: {
        input: { index: resolve(__dirname, 'src/main/index.ts') },
      },
    },
  },

  preload: {
    plugins: [externalizeDepsPlugin()],
    resolve: { alias },
    build: {
      outDir: 'out/preload',
      rollupOptions: {
        input: { index: resolve(__dirname, 'src/preload/index.ts') },
      },
    },
  },

  renderer: {
    root: resolve(__dirname, 'src/renderer'),
    plugins: [react(), tailwindcss()],
    resolve: { alias },
    build: {
      outDir: 'out/renderer',
      rollupOptions: {
        input: {
          panel: resolve(__dirname, 'src/renderer/panel.html'),
          mini: resolve(__dirname, 'src/renderer/mini.html'),
          history: resolve(__dirname, 'src/renderer/history.html'),
          settings: resolve(__dirname, 'src/renderer/settings.html'),
        },
      },
    },
  },
});
