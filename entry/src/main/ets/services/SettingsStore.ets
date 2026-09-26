import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppProxyRule, AppSettings } from '../models/ArkModels';

const STORE_NAME = 'lian_settings';
const KEY_SETTINGS = 'settings.json';
const KEY_ONBOARDING_DONE = 'onboarding_done';
const KEY_LAST_NODE = 'last_node';
/** 分应用代理：只持久化「被关闭（不走代理）」的包名，语义见 ArkModels.AppProxyRule */
const KEY_EXCLUDED_APPS = 'excluded_apps.json';
/** 用户期望的连接意图：'1' 表示用户主动连接过且未主动断开 */
const KEY_WANT_CONNECTED = 'want_connected';
/** 用户手动添加的自定义应用条目（内置目录之外的包名） */
const KEY_CUSTOM_APPS = 'custom_apps.json';

export class SettingsStore {
  private store: preferences.Preferences;

  constructor(context: common.UIAbilityContext) {
    this.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
  }

  /** 上次使用的出口节点（“应用启动后使用上次节点”依赖它） */
  loadLastNode(): string {
    try {
      return this.store.getSync(KEY_LAST_NODE, '') as string;
    } catch (_err) {
      return '';
    }
  }

  saveLastNode(name: string): void {
    if (name.length === 0) {
      return;
    }
    try {
      this.store.putSync(KEY_LAST_NODE, name);
      this.store.flush();
    } catch (_err) {
      // 节点记忆失败不阻断流程
    }
  }

  loadOnboardingDone(): boolean {
    try {
      return this.store.getSync(KEY_ONBOARDING_DONE, false) as boolean;
    } catch (_err) {
      return false;
    }
  }

  saveOnboardingDone(done: boolean): void {
    try {
      this.store.putSync(KEY_ONBOARDING_DONE, done);
      this.store.flush();
    } catch (_err) {
      // 引导状态保存失败不阻断流程
    }
  }

  load(): AppSettings {
    const defaults: AppSettings = {
      autoConnect: true,
      networkRecover: true,
      screenKeep: true,
      failClosed: false,
      notificationOn: true,
      dnsMode: '智能',
      proxyMode: '规则',
      logLevel: 'info',
      testUrl: 'https://www.gstatic.com/generate_204',
      perAppProxyEnabled: false
    };
    try {
      const raw = this.store.getSync(KEY_SETTINGS, '') as string;
      if (raw.length === 0) {
        return defaults;
      }
      const parsed = JSON.parse(raw) as AppSettings;
      if (typeof parsed.autoConnect !== 'boolean' || typeof parsed.networkRecover !== 'boolean') {
        return defaults;
      }
      // 旧存档没有分应用字段：补默认值，避免 undefined 流入 UI
      if (typeof parsed.perAppProxyEnabled !== 'boolean') {
        parsed.perAppProxyEnabled = false;
      }
      return parsed;
    } catch (_err) {
      return defaults;
    }
  }

  save(settings: AppSettings): void {
    try {
      this.store.putSync(KEY_SETTINGS, JSON.stringify(settings));
      this.store.flush();
    } catch (_err) {
      throw new Error('设置保存失败');
    }
  }

  /**
   * 读取「不使用代理」的包名集合。
   *
   * 只持久化黑名单本身，而不是每个应用的开关状态：默认全部应用都走代理，
   * 这样新装/卸载应用不会留下陈旧记录，存档体量也只与黑名单长度相关。
   */
  loadExcludedApps(): string[] {
    try {
      const raw = this.store.getSync(KEY_EXCLUDED_APPS, '') as string;
      if (raw.length === 0) {
        return [];
      }
      const parsed = JSON.parse(raw) as string[];
      if (parsed === null || parsed === undefined) {
        return [];
      }
      const out: string[] = [];
      for (let i = 0; i < parsed.length; i++) {
        const name = parsed[i];
        if (typeof name === 'string' && name.length > 0 && out.indexOf(name) < 0) {
          out.push(name);
        }
      }
      return out;
    } catch (_err) {
      return [];
    }
  }

  saveExcludedApps(bundleNames: string[]): void {
    try {
      this.store.putSync(KEY_EXCLUDED_APPS, JSON.stringify(bundleNames));
      this.store.flush();
    } catch (_err) {
      throw new Error('分应用设置保存失败');
    }
  }

  /**
   * 用户手动添加的自定义应用条目。
   * 与黑名单分开存储：黑名单可能包含内置目录里的应用，而自定义条目是
   * 列表本身的一部分，两者生命周期不同（删条目 ≠ 恢复走代理）。
   */
  loadCustomApps(): AppProxyRule[] {
    try {
      const raw = this.store.getSync(KEY_CUSTOM_APPS, '') as string;
      if (raw.length === 0) {
        return [];
      }
      const parsed = JSON.parse(raw) as AppProxyRule[];
      if (parsed === null || parsed === undefined) {
        return [];
      }
      const out: AppProxyRule[] = [];
      for (let i = 0; i < parsed.length; i++) {
        const item = parsed[i];
        if (item === undefined || item === null) {
          continue;
        }
        if (typeof item.bundleName !== 'string' || item.bundleName.length === 0) {
          continue;
        }
        let dup = false;
        for (let j = 0; j < out.length; j++) {
          if (out[j].bundleName === item.bundleName) {
            dup = true;
            break;
          }
        }
        if (dup) {
          continue;
        }
        out.push({
          bundleName: item.bundleName,
          appName: typeof item.appName === 'string' && item.appName.length > 0
            ? item.appName : item.bundleName,
          proxied: item.proxied !== false
        });
      }
      return out;
    } catch (_err) {
      return [];
    }
  }

  /**
   * 读取「用户是否希望保持连接」的意图标记。
   *
   * 为什么需要它：判断要不要自动重连时**不能依赖 connected 这个内存状态**
   * ——应用进程被杀后重新打开时 connected 初值为 false，于是「隧道其实
   * 应该开着、只是扩展被系统回收了」这种情况会被误判为「用户不想要连接」，
   * 结果界面正确显示「未连接」，却永远不会自动重连。
   * 因此把用户意图持久化：只有用户主动点过断开，才清除该标记。
   */
  loadWantConnected(): boolean {
    try {
      return this.store.getSync(KEY_WANT_CONNECTED, false) as boolean;
    } catch (_err) {
      return false;
    }
  }

  saveWantConnected(want: boolean): void {
    try {
      this.store.putSync(KEY_WANT_CONNECTED, want);
      this.store.flush();
    } catch (_err) {
      // 意图标记写入失败不应阻断连接流程
    }
  }

  saveCustomApps(apps: AppProxyRule[]): void {
    try {
      this.store.putSync(KEY_CUSTOM_APPS, JSON.stringify(apps));
      this.store.flush();
    } catch (_err) {
      throw new Error('自定义应用保存失败');
    }
  }
}
