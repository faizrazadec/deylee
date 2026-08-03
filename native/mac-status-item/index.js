'use strict';

/**
 * Loader for the macOS status-item addon.
 *
 * Never throws. A missing or unbuildable binary is an expected state — on Windows and
 * Linux there is nothing to load, and on macOS a user building from source without the
 * Command Line Tools would otherwise be unable to start the app at all. Callers check
 * `available` and fall back to Electron's own Tray.
 */

let binding = null;

if (process.platform === 'darwin') {
  try {
    binding = require('./build/Release/mac_status_item.node');
  } catch (error) {
    console.error('[dayly] native status item unavailable, falling back to Tray:', error.message);
    binding = null;
  }
}

module.exports = {
  available: binding !== null && binding.supported === true,
  binding,
};
