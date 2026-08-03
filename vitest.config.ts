import { resolve } from 'node:path';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      '@shared': resolve(__dirname, 'src/shared'),
      '@domain': resolve(__dirname, 'src/domain'),
      // The domain layer is pure and needs nothing else, but a couple of main-process
      // services carry logic worth testing on its own — the sleep watchdog's
      // deduplication in particular, which is invisible until it double-counts. Those
      // tests mock `electron`, so nothing here pulls in a real runtime.
      '@main': resolve(__dirname, 'src/main'),
    },
  },
  test: {
    environment: 'node',
    include: ['tests/**/*.test.ts'],
    // The domain layer is pure and timezone-sensitive; pin a zone with a DST
    // transition so the midnight-split tests exercise 23h and 25h days.
    env: { TZ: 'Europe/Berlin' },
  },
});
