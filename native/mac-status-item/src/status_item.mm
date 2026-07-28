// A menu-bar status item that Dayly owns outright.
//
// Electron's Tray wraps NSStatusItem but forwards only a handful of methods to it, and
// the one that held the selection highlight — Tray.setHighlightMode — was removed in
// Electron 7, when the tray was rewritten on top of [NSStatusItem button] to survive
// macOS Catalina. Nothing replaced it, so a menu-bar app with a custom panel cannot
// show the "I am open" state that every other macOS menu-bar app shows.
//
// Owning the NSStatusItem ourselves gets it back. Everything here is public AppKit;
// nothing reaches into Electron's internals.
//
// Threading: every entry point is called from the Electron main process, which is the
// AppKit main thread, so the main-thread-only rules for AppKit hold by construction.
// Callbacks the other way go through a ThreadSafeFunction so they land on the Node
// event loop instead of re-entering JS from inside an AppKit event.

#include <napi.h>
#import <Cocoa/Cocoa.h>

#include <string>

@class DaylyStatusTarget;

namespace {

NSStatusItem* g_item = nil;
NSMenu* g_menu = nil;
/** Mirrors the button's highlight so a click can toggle it without asking AppKit. */
BOOL g_highlighted = NO;
DaylyStatusTarget* g_target = nil;
Napi::ThreadSafeFunction g_on_click;
Napi::ThreadSafeFunction g_on_command;
bool g_has_click = false;
bool g_has_command = false;

/** Queues "left" or "right" to the JS click handler. */
void EmitClick(const char* button) {
  if (!g_has_click) return;
  std::string which(button);
  g_on_click.NonBlockingCall([which](Napi::Env env, Napi::Function fn) {
    fn.Call({Napi::String::New(env, which)});
  });
}

/** Queues a menu command id to the JS handler. */
void EmitCommand(int32_t id) {
  if (!g_has_command) return;
  g_on_command.NonBlockingCall(
      [id](Napi::Env env, Napi::Function fn) { fn.Call({Napi::Number::New(env, id)}); });
}

}  // namespace

/**
 * Action target for the status button and for every menu item.
 *
 * A right click — or a control-click, which macOS treats identically — attaches the
 * menu, clicks the button to open it, then detaches it again. The attach must be
 * temporary: a permanently attached menu makes AppKit open it on *left* click too,
 * which is the exact bug this app already had, with the menu landing on top of the
 * panel the same click had just opened.
 */
@interface DaylyStatusTarget : NSObject
- (void)onButton:(id)sender;
- (void)onMenuItem:(id)sender;
@end

@implementation DaylyStatusTarget

- (void)onButton:(id)sender {
  (void)sender;
  NSEvent* event = [NSApp currentEvent];
  BOOL secondary = NO;
  if (event != nil) {
    secondary = event.type == NSEventTypeRightMouseUp ||
                event.type == NSEventTypeRightMouseDown ||
                (event.modifierFlags & NSEventModifierFlagControl) != 0;
  }

  if (secondary && g_menu != nil && g_item != nil) {
    g_item.menu = g_menu;
    [g_item.button performClick:nil];
    // Detach on the next turn of the run loop rather than inline: the menu tracking
    // loop is still unwinding here, and clearing it immediately dismisses the menu
    // the user just asked for.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_item != nil) g_item.menu = nil;
    });
    return;
  }

  // Take the highlight here rather than waiting for JS to come back.
  //
  // AppKit's own press feedback clears on mouse-up, and the round trip to JS — thread
  // safe callback, panel toggle, window 'show' event — lands a tick or two later. The
  // result is a visible flash off and back on. Toggling it now, in the same gesture
  // that opens the panel, makes the two continuous; `setHighlighted` from JS then
  // reconciles if the panel did something other than what was assumed.
  //
  // Deferred by one run-loop turn because the button clears its momentary highlight as
  // part of the very mouse-up that invoked this action; setting it inline is undone.
  if (!secondary) {
    g_highlighted = !g_highlighted;
    const BOOL wanted = g_highlighted;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_item != nil) [g_item.button setHighlighted:wanted];
    });
  }

  EmitClick(secondary ? "right" : "left");
}

- (void)onMenuItem:(id)sender {
  NSMenuItem* item = (NSMenuItem*)sender;
  EmitCommand((int32_t)item.tag);
}

@end

/* -------------------------------------------------------------------------- */
/* Bindings                                                                    */
/* -------------------------------------------------------------------------- */

Napi::Value Create(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (g_item != nil) return Napi::Boolean::New(env, true);

  g_target = [[DaylyStatusTarget alloc] init];
  g_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  if (g_item == nil) return Napi::Boolean::New(env, false);

  NSStatusBarButton* button = g_item.button;
  button.target = g_target;
  button.action = @selector(onButton:);
  // Without this the button reports only left clicks, so right-click would never
  // reach us to open the menu.
  [button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

  return Napi::Boolean::New(env, true);
}

Napi::Value Destroy(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (g_item != nil) {
    [[NSStatusBar systemStatusBar] removeStatusItem:g_item];
    g_item = nil;
  }
  g_menu = nil;
  g_target = nil;
  if (g_has_click) {
    g_on_click.Release();
    g_has_click = false;
  }
  if (g_has_command) {
    g_on_command.Release();
    g_has_command = false;
  }
  return env.Undefined();
}

Napi::Value SetImage(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (g_item == nil) return env.Undefined();
  std::string path = info[0].As<Napi::String>().Utf8Value();
  bool is_template = info.Length() > 1 && info[1].ToBoolean().Value();

  NSString* ns_path = [NSString stringWithUTF8String:path.c_str()];
  NSImage* image = [[NSImage alloc] initWithContentsOfFile:ns_path];
  if (image == nil || !image.isValid) return env.Undefined();

  // Pull in the @2x sibling as a second representation.
  //
  // Electron's nativeImage.createFromPath finds it for you; a raw NSImage does not, so
  // loading only the 16px file left AppKit upscaling it on a Retina display and the
  // icon came out visibly soft. Adding the 32px rep and sizing the image in *points*
  // lets AppKit choose the right one for each display's backing scale.
  NSString* stem = [ns_path stringByDeletingPathExtension];
  NSString* ext = [ns_path pathExtension];
  NSString* retina = [NSString stringWithFormat:@"%@@2x.%@", stem, ext];
  NSImageRep* rep = [NSImageRep imageRepWithContentsOfFile:retina];
  if (rep != nil) [image addRepresentation:rep];

  // Points, not pixels. The artwork is authored at 16pt with a 32px @2x, which is what
  // the rest of the app ships; scaling it to 18 was what blurred it.
  [image setSize:NSMakeSize(16, 16)];

  // A template image is recoloured by AppKit for the current menu bar — including the
  // inverted look while the item is highlighted, which is the entire reason for owning
  // this item, so it must stay a template. Spelled as the setter, not
  // `image.template` — `template` is a C++ keyword and this file is Objective-C++.
  [image setTemplate:is_template];
  g_item.button.image = image;
  return env.Undefined();
}

Napi::Value SetTitle(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (g_item == nil) return env.Undefined();
  std::string title = info[0].As<Napi::String>().Utf8Value();
  g_item.button.title = [NSString stringWithUTF8String:title.c_str()];
  // Keeps the glyph from overlapping the label, and collapses the gap when the label
  // is empty (idle, where the icon stands alone).
  g_item.button.imagePosition = title.empty() ? NSImageOnly : NSImageLeft;
  return env.Undefined();
}

Napi::Value SetToolTip(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (g_item == nil) return env.Undefined();
  std::string tip = info[0].As<Napi::String>().Utf8Value();
  g_item.button.toolTip = [NSString stringWithUTF8String:tip.c_str()];
  return env.Undefined();
}

/**
 * The reason this addon exists.
 *
 * Also the reconciliation point for the optimistic toggle in `onButton:` — whatever
 * the panel actually did wins, so the two cannot drift apart.
 */
Napi::Value SetHighlighted(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (g_item == nil) return env.Undefined();
  g_highlighted = info[0].ToBoolean().Value() ? YES : NO;
  [g_item.button setHighlighted:g_highlighted];
  return env.Undefined();
}

/**
 * The button's frame in Electron screen coordinates.
 *
 * AppKit's origin is the bottom-left of the primary screen with y increasing upward;
 * Electron's is the top-left with y increasing downward, so y is flipped against the
 * primary screen's height.
 */
Napi::Value GetFrame(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (g_item == nil) return env.Null();
  NSStatusBarButton* button = g_item.button;
  NSWindow* window = button.window;
  if (window == nil) return env.Null();

  NSRect in_window = [button convertRect:button.bounds toView:nil];
  NSRect on_screen = [window convertRectToScreen:in_window];

  NSArray<NSScreen*>* screens = [NSScreen screens];
  if (screens.count == 0) return env.Null();
  CGFloat primary_height = screens[0].frame.size.height;

  Napi::Object out = Napi::Object::New(env);
  out.Set("x", Napi::Number::New(env, on_screen.origin.x));
  out.Set("y", Napi::Number::New(env, primary_height - NSMaxY(on_screen)));
  out.Set("width", Napi::Number::New(env, on_screen.size.width));
  out.Set("height", Napi::Number::New(env, on_screen.size.height));
  return out;
}

/**
 * Rebuilds the context menu from a plain description.
 *
 * The menu is described in JS and built here rather than handed over as an Electron
 * `Menu`, because there is no public way to get the underlying NSMenu out of one.
 * Items are `{ id, label, enabled }` or `{ separator: true }`.
 */
Napi::Value SetMenu(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Array items = info[0].As<Napi::Array>();

  NSMenu* menu = [[NSMenu alloc] init];
  // Without this AppKit greys out every item, because nothing here implements the
  // validation protocol it would otherwise consult.
  menu.autoenablesItems = NO;

  for (uint32_t i = 0; i < items.Length(); i++) {
    Napi::Object entry = items.Get(i).As<Napi::Object>();
    if (entry.Get("separator").ToBoolean().Value()) {
      [menu addItem:[NSMenuItem separatorItem]];
      continue;
    }
    std::string label = entry.Get("label").As<Napi::String>().Utf8Value();
    NSMenuItem* item =
        [[NSMenuItem alloc] initWithTitle:[NSString stringWithUTF8String:label.c_str()]
                                   action:@selector(onMenuItem:)
                            keyEquivalent:@""];
    item.target = g_target;
    item.tag = entry.Get("id").As<Napi::Number>().Int32Value();
    item.enabled = entry.Get("enabled").ToBoolean().Value();
    [menu addItem:item];
  }

  g_menu = menu;
  return env.Undefined();
}

Napi::Value OnClick(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (g_has_click) g_on_click.Release();
  g_on_click = Napi::ThreadSafeFunction::New(env, info[0].As<Napi::Function>(),
                                             "daylyStatusItemClick", 0, 1);
  g_has_click = true;
  return env.Undefined();
}

Napi::Value OnCommand(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (g_has_command) g_on_command.Release();
  g_on_command = Napi::ThreadSafeFunction::New(env, info[0].As<Napi::Function>(),
                                               "daylyStatusItemCommand", 0, 1);
  g_has_command = true;
  return env.Undefined();
}

static Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set("supported", Napi::Boolean::New(env, true));
  exports.Set("create", Napi::Function::New(env, Create));
  exports.Set("destroy", Napi::Function::New(env, Destroy));
  exports.Set("setImage", Napi::Function::New(env, SetImage));
  exports.Set("setTitle", Napi::Function::New(env, SetTitle));
  exports.Set("setToolTip", Napi::Function::New(env, SetToolTip));
  exports.Set("setHighlighted", Napi::Function::New(env, SetHighlighted));
  exports.Set("getFrame", Napi::Function::New(env, GetFrame));
  exports.Set("setMenu", Napi::Function::New(env, SetMenu));
  exports.Set("onClick", Napi::Function::New(env, OnClick));
  exports.Set("onCommand", Napi::Function::New(env, OnCommand));
  return exports;
}

NODE_API_MODULE(mac_status_item, Init)
