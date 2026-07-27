import { resolve } from 'node:path';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      '@shared': resolve(__dirname, 'src/shared'),
      '@domain': resolve(__dirname, 'src/domain'),
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
