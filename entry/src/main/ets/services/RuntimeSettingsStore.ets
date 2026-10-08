import { common } from '@kit.AbilityKit';
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x2028;
const TAG = 'RuntimeSettings';
const RUNTIME_FILE = '/lian-runtime-settings.json';

export interface RuntimeSettings {
  networkRecover: boolean;
  failClosed: boolean;
}

const DEFAULTS: RuntimeSettings = {
  networkRecover: true,
  failClosed: false
};

/** UI 与 VPN 扩展进程共享的小型运行时配置。 */
export class RuntimeSettingsStore {
  private dir: string;

  constructor(context: common.UIAbilityContext) {
    this.dir = context.filesDir;
  }

  save(settings: RuntimeSettings): void {
    const path: string = this.dir + RUNTIME_FILE;
    const tmp: string = path + '.tmp';
    let fd: number = -1;
    try {
      const file = fileIo.openSync(tmp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fd = file.fd;
      fileIo.writeSync(fd, JSON.stringify(settings));
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
    } catch (_err) {
      hilog.error(DOMAIN, TAG, 'save rename failed');
      throw new Error('运行时设置写入失败');
    }
  }
}

export class RuntimeSettingsReader {
  static read(filesDir: string): RuntimeSettings {
    try {
      const raw: string = fileIo.readTextSync(filesDir + RUNTIME_FILE);
      const parsed = JSON.parse(raw) as RuntimeSettings;
      if (parsed === null || parsed === undefined) {
        return DEFAULTS;
      }
      return {
        networkRecover: typeof parsed.networkRecover === 'boolean' ? parsed.networkRecover : true,
        failClosed: typeof parsed.failClosed === 'boolean' ? parsed.failClosed : false
      };
    } catch (_err) {
      return DEFAULTS;
    }
  }
}
