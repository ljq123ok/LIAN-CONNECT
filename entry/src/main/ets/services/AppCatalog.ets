import { common } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppProxyRule } from '../models/ArkModels';

const DOMAIN = 0x2026;
const TAG = 'AppCatalog';

/**
 * 分应用代理的应用清单。
 *
 * ## 为什么是「内置目录 + 按包名校验」而不是运行时枚举
 *
 * FlClash 在 Android 上用 PackageManager 列出全部已安装应用。HarmonyOS 上这条路
 * 走不通，依据（已核对本机 SDK 与签名 profile，非推测）：
 *
 *  - `bundleManager.getAllApplicationInfo` / `getAllBundleInfo`
 *    → 需要 `ohos.permission.GET_BUNDLE_INFO_PRIVILEGED`，
 *      `availableLevel = system_basic`（SDK `PermissionDefinitions.json`）；
 *  - `GET_INSTALLED_BUNDLE_LIST` → `system_basic` + `user_grant`；
 *  - `getLauncherAbilityInfoSync` → 同样 `GET_BUNDLE_INFO_PRIVILEGED`；
 *  - `getRunningProcessInformation()` 不加权限只返回**自己**（API 文档原文：
 *    "If you do not apply, you can only obtain information about the current process"）。
 *
 * 而本工程签名 profile 实测为：`"apl":"normal"`、`"acls":{"allowed-acls":[]}`
 * —— 没有任何 ACL 提权，因此 system_basic 级权限申请不到。
 *
 * ## 可行的做法
 *
 * `getBundleInfo(bundleName, ...)` 同时接受 `GET_BUNDLE_INFO`（level=normal，
 * system_grant，装上即得）。所以：
 *
 *  - **能**：按包名查询 → 校验是否已安装、拿到显示名与图标；
 *  - **不能**：列出全部已安装应用。
 *
 * 于是设计为「内置常见应用目录（可搜索）＋ 任意包名手动输入」，两者都走
 * `getBundleInfo` 校验，效果与选择器接近且零权限依赖。
 *
 * 目录按「本机真实安装情况」筛选过：下列条目均取自设备 `bm dump -a` 的实测
 * 包名，并剔除了后台服务类包（如各类 *Service / *provider）。
 */
export class AppCatalog {
  /** 主用户 userId；传 0 或负数会抛 17700004 */
  private static readonly USER_ID: number = 100;

  /**
   * 内置目录。`pkg` 为包名，`name` 为中文名。
   * 命中已安装时以系统返回的真实 label 为准，这里只作为未安装/取不到时的兜底。
   */
  private static readonly ENTRIES: AppProxyRule[] = [
    // ---- 社交 / 通讯 ----
    { bundleName: 'com.tencent.wechat', appName: '微信', proxied: true },
    { bundleName: 'com.tencent.mqq', appName: 'QQ', proxied: true },
    { bundleName: 'com.dingtalk.hmos', appName: '钉钉', proxied: true },
    { bundleName: 'com.alipay.mobile.client', appName: '支付宝', proxied: true },

    // ---- 购物 / 生活 ----
    { bundleName: 'com.taobao.taobao4hmos', appName: '淘宝', proxied: true },
    { bundleName: 'com.taobao.idlefish4ohos', appName: '闲鱼', proxied: true },
    { bundleName: 'com.jd.hm.mall', appName: '京东', proxied: true },
    { bundleName: 'com.xunmeng.pinduoduo.hos', appName: '拼多多', proxied: true },
    { bundleName: 'com.sankuai.hmeituan', appName: '美团', proxied: true },
    { bundleName: 'com.amap.hmapp', appName: '高德地图', proxied: true },
    { bundleName: 'com.chinarailway.ticketingHM', appName: '铁路12306', proxied: true },
    { bundleName: 'com.tmri.app.harmony12123', appName: '交管12123', proxied: true },

    // ---- 内容 / 娱乐 ----
    { bundleName: 'com.ss.hm.ugc.aweme', appName: '抖音', proxied: true },
    { bundleName: 'yylx.danmaku.bili', appName: '哔哩哔哩', proxied: true },
    { bundleName: 'com.qidian.reader', appName: '起点读书', proxied: true },
    { bundleName: 'com.yuewen.authorapphm', appName: '作家助手', proxied: true },
    { bundleName: 'com.xingin.xhs_hos', appName: '小红书', proxied: true },
    { bundleName: 'com.phoenix.read.next', appName: '番茄小说', proxied: true },
    { bundleName: 'com.coolapk.hmclient', appName: '酷安', proxied: true },
    { bundleName: 'com.dgtle.app', appName: '数字尾巴', proxied: true },
    { bundleName: 'com.max.hos.xiaoheihe', appName: '小黑盒', proxied: true },

    // ---- 工具 / 办公 ----
    { bundleName: 'com.huawei.hmos.browser', appName: '华为浏览器', proxied: true },
    { bundleName: 'com.quark.ohosbrowser', appName: '夸克浏览器', proxied: true },
    { bundleName: 'cn.wps.mobileoffice.hap', appName: 'WPS Office', proxied: true },
    { bundleName: 'com.intsig.camscanner.hap', appName: '扫描全能王', proxied: true },
    { bundleName: 'com.baidu.netdisk.hmos', appName: '百度网盘', proxied: true },
    { bundleName: 'com.sogou.input', appName: '搜狗输入法', proxied: true },

    // ---- 金融 / 出行 / 运营商 ----
    { bundleName: 'com.unionpay.hmos.wallet', appName: '云闪付', proxied: true },
    { bundleName: 'com.huawei.hmos.wallet', appName: '华为钱包', proxied: true },
    { bundleName: 'cn.gov.tax.its.hm', appName: '个人所得税', proxied: true },
    { bundleName: 'cn.hsa.app.hos', appName: '国家医保服务平台', proxied: true },
    { bundleName: 'com.chinamobile.cmcc', appName: '中国移动', proxied: true },
    { bundleName: 'com.sinovatech.unicom.ha', appName: '中国联通', proxied: true },
    { bundleName: 'com.byd.hauto', appName: '比亚迪', proxied: true },

    // ---- 游戏 ----
    { bundleName: 'com.tencent.lolm.hw', appName: '英雄联盟手游', proxied: true },
    { bundleName: 'com.tencent.jkchess.huawei', appName: '金铲铲之战', proxied: true },

    // ---- 其它 ----
    { bundleName: 'com.ezviz.videogo', appName: '萤石云视频', proxied: true },
    { bundleName: 'com.huawei.hmos.health', appName: '运动健康', proxied: true }
  ];

  /** 内置目录（按名称排序，供列表展示） */
  static entries(): AppProxyRule[] {
    const out: AppProxyRule[] = [];
    for (let i = 0; i < AppCatalog.ENTRIES.length; i++) {
      const e = AppCatalog.ENTRIES[i];
      out.push({ bundleName: e.bundleName, appName: e.appName, proxied: e.proxied });
    }
    return out;
  }

  /**
   * 尝试按包名取系统显示名。
   *
   * 真机验证中，普通第三方应用可能无权查询其它包的系统显示名并返回空串。
   * 即使已声明 `GET_BUNDLE_INFO`，部分系统版本的 BMS 服务端仍可能要求
   * 系统应用权限。
   *
   * 保留此函数只为「平台将来放开」的兼容路径；调用方**必须**接受空串并回退
   * 到内置名称，绝不能把失败解读为「未安装」。
   */
  static resolveLabel(context: common.UIAbilityContext, bundleName: string): string {
    if (!AppCatalog.isValidBundleName(bundleName)) {
      return '';
    }
    try {
      // userId 固定 100（本机主用户）；传 0/负数会抛 17700004。
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoSync(
        bundleName,
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION,
        AppCatalog.USER_ID
      );
      const app = info.appInfo;
      if (app !== undefined && app !== null && app.label !== undefined && app.label.length > 0) {
        return app.label;
      }
    } catch (err) {
      hilog.debug(DOMAIN, TAG, 'resolveLabel unavailable');
    }
    return '';
  }

  /**
   * 包名格式校验：至少两段、以点分隔、仅含字母/数字/下划线。
   *
   * **只做格式检查**，不能校验「是否已安装」：见 resolveLabel 的说明，BMS
   * 拒绝第三方应用查询其它包，且没有替代 API（枚举类接口全部需要
   * system_basic 级权限，本工程签名 profile 的 acls 为空）。
   *
   * 因此 UI 也不应展示「未安装」之类结论——那会把「查不到」误报成「没装」。
   */
  static isValidBundleName(bundleName: string): boolean {
    if (bundleName.length < 3 || bundleName.length > 128) {
      return false;
    }
    if (bundleName.indexOf('.') < 0) {
      return false;
    }
    // 反域名规则：每段非空，且不含空格/斜杠等非法字符
    const segs: string[] = bundleName.split('.');
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      if (s.length === 0) {
        return false;
      }
      if (!/^[A-Za-z0-9_]+$/.test(s)) {
        return false;
      }
    }
    return true;
  }
}
