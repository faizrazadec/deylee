/**
 * Commit messages are the input to versioning: `commit-and-tag-version` derives the
 * next version from them. A malformed message does not fail loudly at release time —
 * it silently drops the change out of the changelog and can skip a release entirely.
 * So the rules are enforced at commit time by the husky `commit-msg` hook instead.
 */
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Scopes track the module boundaries in docs/ARCHITECTURE.md. Optional, but when
    // present it has to be one of these, so the changelog groups predictably.
    'scope-enum': [
      2,
      'always',
      [
        'db',
        'domain',
        'timer',
        'tray',
        'platform',
        'windows',
        'ipc',
        'preload',
        'panel',
        'mini',
        'history',
        'settings',
        'updater',
        'icons',
        'build',
        'deps',
        'docs',
        'ci',
      ],
    ],
    'subject-case': [2, 'never', ['start-case', 'pascal-case', 'upper-case']],
    'subject-full-stop': [2, 'never', '.'],
    'header-max-length': [2, 'always', 72],
    'body-max-line-length': [2, 'always', 100],
  },
};
