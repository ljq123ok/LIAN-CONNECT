import { common } from '@kit.AbilityKit';
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x2025;
const TAG = 'GeoAssets';

const GEOSITE_FILE = 'geosite.dat';
const GEOIP_FILE = 'geoip.metadb';
const GEOIP_ALT = 'geoip.db';

/**
 * 内置 geo 规则数据（geosite.dat / geoip.metadb）落地到核心工作目录。
 * 有了这两个文件，生成配置就能使用 GEOSITE,cn / GEOIP,CN 做国内直连分流，
 * 而不再依赖手写的少量域名列表；文件随 App 打包，无需联网下载。
 */
export class GeoAssets {
  /** 目标文件是否已就绪 */
  static available(homeDir: string): boolean {
    return GeoAssets.exists(homeDir + '/' + GEOSITE_FILE) && GeoAssets.geoipPath(homeDir).length > 0;
  }

  private static exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_err) {
      return false;
    }
  }

  private static geoipPath(homeDir: string): string {
    if (GeoAssets.exists(homeDir + '/' + GEOIP_FILE)) {
      return homeDir + '/' + GEOIP_FILE;
    }
    if (GeoAssets.exists(homeDir + '/' + GEOIP_ALT)) {
      return homeDir + '/' + GEOIP_ALT;
    }
    return '';
  }

  /**
   * 确保 geo 文件存在于工作目录。已存在则直接返回，不重复拷贝。
   * @returns 是否可用
   */
  static ensure(context: common.UIAbilityContext, homeDir: string): boolean {
    if (GeoAssets.available(homeDir)) {
      return true;
    }
    GeoAssets.copyIfMissing(context, homeDir, GEOSITE_FILE);
    GeoAssets.copyIfMissing(context, homeDir, GEOIP_FILE);
    return GeoAssets.available(homeDir);
  }

  private static copyIfMissing(context: common.UIAbilityContext, homeDir: string, name: string): void {
    const target = homeDir + '/' + name;
    if (GeoAssets.exists(target)) {
      return;
    }
    try {
      const bytes = context.resourceManager.getRawFileContentSync('geo/' + name);
      let fd = -1;
      const file = fileIo.openSync(target,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fd = file.fd;
      try {
        fileIo.writeSync(fd, bytes.buffer as ArrayBuffer);
      } finally {
        if (fd >= 0) {
          fileIo.closeSync(fd);
        }
      }
      hilog.info(DOMAIN, TAG, 'geo asset staged: %{public}s', name);
    } catch (err) {
      // 缺少内置资源时静默回退到内置域名规则
      hilog.warn(DOMAIN, TAG, 'geo asset staging failed: %{public}s', name);
    }
  }
}
