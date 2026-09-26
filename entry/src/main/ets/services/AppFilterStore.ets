import { common } from '@kit.AbilityKit';
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x2027;
const TAG = 'AppFilter';

/** 与扩展进程共享的文件（UIAbility 与 VpnExtensionAbility 同沙箱、同 filesDir） */
const FILTER_FILE = '/lian-app-filter.json';

export interface AppFilterConfig {
  /** 分应用代理是否启用 */
  enabled: boolean;
  /**
   * **不使用代理**的包名（FlClash 语义下的黑名单：关 = 直连）。
   * 未列入其中的应用一律走代理。
   */
  excluded: string[];
}

/**
 * 分应用代理的落地配置：由 UI 进程写入、VPN 扩展进程读取。
 *
 * 为什么要走文件而不是 Want 参数：
 * `VpnConfig` 只在 `VpnConnection.create()` 时生效，而 create 发生在扩展进程的
 * `createTun()` 里。UI 与扩展是两个进程，沿用本工程既有的
 * `lian-active-config.json` 文件交接模式最稳，也避免 Want 参数长度限制。
 */
export class AppFilterStore {
  private dir: string;

  constructor(context: common.UIAbilityContext) {
    this.dir = context.filesDir;
  }

  /** UI 侧：保存后写盘（原子替换，避免扩展读到半截 JSON） */
  save(config: AppFilterConfig): void {
    const path = this.dir + FILTER_FILE;
    const tmp = path + '.tmp';
    let fd = -1;
    try {
      const f = fileIo.openSync(tmp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fd = f.fd;
      fileIo.writeSync(fd, JSON.stringify(config));
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (_err) {
        }
      }
    }
    try {
      fileIo.renameSync(tmp, path);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save rename failed: %{public}s', `${err}`);
      throw new Error('分应用配置写入失败');
    }
  }

  load(): AppFilterConfig {
    try {
      const raw = fileIo.readTextSync(this.dir + FILTER_FILE);
      if (raw.length === 0) {
        return { enabled: false, excluded: [] };
      }
      const parsed = JSON.parse(raw) as AppFilterConfig;
      if (parsed === null || parsed === undefined) {
        return { enabled: false, excluded: [] };
      }
      return {
        enabled: parsed.enabled === true,
        excluded: parsed.excluded !== undefined && parsed.excluded !== null ? parsed.excluded : []
      };
    } catch (_err) {
      return { enabled: false, excluded: [] };
    }
  }
}

/**
 * 扩展侧读取（静态方法，避免扩展进程依赖 UIAbilityContext）。
 * @param filesDir VpnExtensionContext.filesDir —— 与 UIAbility 同沙箱
 */
export class AppFilterReader {
  static read(filesDir: string): AppFilterConfig {
    try {
      const raw = fileIo.readTextSync(filesDir + FILTER_FILE);
      if (raw.length === 0) {
        return { enabled: false, excluded: [] };
      }
      const parsed = JSON.parse(raw) as AppFilterConfig;
      if (parsed === null || parsed === undefined || parsed.enabled !== true) {
        return { enabled: false, excluded: [] };
      }
      const excluded: string[] = [];
      const src = parsed.excluded !== undefined && parsed.excluded !== null ? parsed.excluded : [];
      for (let i = 0; i < src.length; i++) {
        const name = src[i];
        if (typeof name === 'string' && name.length > 0 && excluded.indexOf(name) < 0) {
          excluded.push(name);
        }
      }
      return { enabled: true, excluded: excluded };
    } catch (_err) {
      // 文件不存在或损坏：视为未启用，不影响连接
      return { enabled: false, excluded: [] };
    }
  }
}
