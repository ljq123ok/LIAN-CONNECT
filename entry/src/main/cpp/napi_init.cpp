#include "napi/native_api.h"
#include <hilog/log.h>
#include <dlfcn.h>
#include <string>

typedef char *(*fn_start)(char *, char *, int32_t);
typedef char *(*fn_status)(void);
typedef char *(*fn_version)(void);
typedef void (*fn_stop)(void);
typedef void (*fn_free)(char *);
typedef char *(*fn_connections)(void);
typedef char *(*fn_setmode)(char *);
typedef char *(*fn_closeconn)(char *);
typedef char *(*fn_health)(void);
// 手动指定出口节点：参数为 (组名, 节点名)
typedef char *(*fn_selectnode)(char *, char *);

static fn_start p_start = nullptr;
static fn_status p_status = nullptr;
static fn_version p_version = nullptr;
static fn_stop p_stop = nullptr;
static fn_free p_free = nullptr;
static fn_connections p_connections = nullptr;
static fn_setmode p_setmode = nullptr;
static fn_closeconn p_closeconn = nullptr;
static fn_health p_health = nullptr;
static fn_selectnode p_selectnode = nullptr;
static bool g_tried = false;
static bool g_loaded = false;

static void EnsureCore() {
  if (g_tried) {
    return;
  }
  g_tried = true;
  void *h = dlopen("libmihomo_ohos.so", RTLD_NOW | RTLD_GLOBAL);
  if (!h) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0x2020, "lianbridge",
                 "dlopen libmihomo_ohos.so FAILED: %{public}s", dlerror());
    return;
  }
  p_start = reinterpret_cast<fn_start>(dlsym(h, "LianCoreStart"));
  p_status = reinterpret_cast<fn_status>(dlsym(h, "LianCoreStatus"));
  p_version = reinterpret_cast<fn_version>(dlsym(h, "LianCoreVersion"));
  p_stop = reinterpret_cast<fn_stop>(dlsym(h, "LianCoreStop"));
  p_free = reinterpret_cast<fn_free>(dlsym(h, "LianCoreFree"));
  p_connections = reinterpret_cast<fn_connections>(dlsym(h, "LianCoreConnections"));
  p_setmode = reinterpret_cast<fn_setmode>(dlsym(h, "LianCoreSetMode"));
  p_closeconn = reinterpret_cast<fn_closeconn>(dlsym(h, "LianCoreCloseConnection"));
  p_health = reinterpret_cast<fn_health>(dlsym(h, "LianCoreHealth"));
  p_selectnode = reinterpret_cast<fn_selectnode>(dlsym(h, "LianCoreSelectNode"));
  g_loaded = p_start && p_status && p_version && p_stop && p_free;
  OH_LOG_Print(LOG_APP, LOG_ERROR, 0x2020, "lianbridge",
               "mihomo core loaded=%{public}d (start=%{public}p status=%{public}p)",
               g_loaded ? 1 : 0, reinterpret_cast<void *>(p_start),
               reinterpret_cast<void *>(p_status));
}

static std::string ArgToString(napi_env env, napi_value v) {
  size_t len = 0;
  napi_get_value_string_utf8(env, v, nullptr, 0, &len);
  std::string s(len, '\0');
  napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
  return s;
}

static napi_value GoString(napi_env env, char *cs) {
  napi_value out = nullptr;
  napi_create_string_utf8(env, cs ? cs : "", NAPI_AUTO_LENGTH, &out);
  if (cs && p_free) {
    p_free(cs);
  }
  return out;
}

static napi_value Start(napi_env env, napi_callback_info info) {
  EnsureCore();
  size_t argc = 3;
  napi_value args[3] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (!p_start) {
    return GoString(env, nullptr);
  }
  int32_t fd = -1;
  napi_get_value_int32(env, args[0], &fd);
  std::string configPath = ArgToString(env, args[1]);
  std::string homeDir = ArgToString(env, args[2]);
  char *r = p_start(const_cast<char *>(configPath.c_str()),
                    const_cast<char *>(homeDir.c_str()), fd);
  return GoString(env, r);
}

static napi_value Status(napi_env env, napi_callback_info info) {
  EnsureCore();
  return GoString(env, p_status ? p_status() : nullptr);
}

static napi_value Version(napi_env env, napi_callback_info info) {
  EnsureCore();
  return GoString(env, p_version ? p_version() : nullptr);
}

static napi_value Stop(napi_env env, napi_callback_info info) {
  EnsureCore();
  if (p_stop) {
    p_stop();
  }
  napi_value undef = nullptr;
  napi_get_undefined(env, &undef);
  return undef;
}

static napi_value Connections(napi_env env, napi_callback_info info) {
  EnsureCore();
  return GoString(env, p_connections ? p_connections() : nullptr);
}

// 手动指定出口节点（组名可为空 = 主组）。
// 这一层必须显式转发：Go 的导出符号经由 dlsym 绑定后再注册给 JS，
// 只加 Go 侧函数而漏了这里，JS 会拿到 undefined 而静默失效。
static napi_value SelectNode(napi_env env, napi_callback_info info) {
  EnsureCore();
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (!p_selectnode || argc < 2) {
    return GoString(env, nullptr);
  }
  std::string group = ArgToString(env, args[0]);
  std::string name = ArgToString(env, args[1]);
  return GoString(env, p_selectnode(const_cast<char *>(group.c_str()),
                                    const_cast<char *>(name.c_str())));
}

static napi_value SetMode(napi_env env, napi_callback_info info) {
  EnsureCore();
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (!p_setmode || argc < 1) {
    return GoString(env, nullptr);
  }
  std::string mode = ArgToString(env, args[0]);
  return GoString(env, p_setmode(const_cast<char *>(mode.c_str())));
}

static napi_value CloseConnection(napi_env env, napi_callback_info info) {
  EnsureCore();
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (!p_closeconn || argc < 1) {
    return GoString(env, nullptr);
  }
  std::string id = ArgToString(env, args[0]);
  return GoString(env, p_closeconn(const_cast<char *>(id.c_str())));
}

static napi_value Health(napi_env env, napi_callback_info info) {
  EnsureCore();
  return GoString(env, p_health ? p_health() : nullptr);
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"start",   nullptr, Start,   nullptr, nullptr, nullptr, napi_default, nullptr},
      {"status",  nullptr, Status,  nullptr, nullptr, nullptr, napi_default, nullptr},
      {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stop",    nullptr, Stop,    nullptr, nullptr, nullptr, napi_default, nullptr},
      {"connections", nullptr, Connections, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setMode",     nullptr, SetMode,     nullptr, nullptr, nullptr, napi_default, nullptr},
      {"closeConnection", nullptr, CloseConnection, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"health",          nullptr, Health,          nullptr, nullptr, nullptr, napi_default, nullptr},
      {"selectNode",      nullptr, SelectNode,      nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

static napi_module lianBridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "lianbridge",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterLianBridgeModule(void) {
  napi_module_register(&lianBridgeModule);
}
