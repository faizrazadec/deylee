// Windows and Linux keep using Electron's Tray; this target exists only so the
// addon builds to a loadable no-op everywhere, rather than failing the install.
#include <napi.h>

static Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set("supported", Napi::Boolean::New(env, false));
  return exports;
}

NODE_API_MODULE(mac_status_item, Init)
