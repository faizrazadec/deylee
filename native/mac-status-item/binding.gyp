{
  "targets": [
    {
      "target_name": "mac_status_item",
      "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"],
      "include_dirs": ["<!@(node -p \"require('node-addon-api').include_dir\")"],
      "conditions": [
        ["OS=='mac'", {
          "sources": ["src/status_item.mm"],
          "link_settings": { "libraries": ["-framework Cocoa"] },
          "xcode_settings": {
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "GCC_ENABLE_CPP_EXCEPTIONS": "NO",
            "MACOSX_DEPLOYMENT_TARGET": "11.0"
          }
        }],
        ["OS!='mac'", {
          "sources": ["src/unsupported.cc"]
        }]
      ]
    }
  ]
}
