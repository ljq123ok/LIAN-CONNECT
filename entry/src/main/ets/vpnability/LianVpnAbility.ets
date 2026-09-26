import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import { vpnExtension, connection } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import * as lianbridge from 'liblianbridge.so';
import { AppFilterReader } from '../services/AppFilterStore';

const DOMAIN = 0x2020;
const TAG = 'LianVpn';
const BUNDLE = 'com.lianconnect.app';
const ACTIVE_CONFIG_FILE = '/lian-active-config.json';
const VPN_IP = '10.6.0.2';
const MANUAL_GROUP_NAME = '手动选择';
const TUN_RECOVER_BASE_DELAY_MS = 5 * 60 * 1000;
const TUN_RECOVER_MAX_ATTEMPTS = 3;

/**
 * 排除集合走哪个 VpnConfig 字段 —— 单点可翻转的实测开关。
 *
 * `true`  = 用 `blockedApplications`（blocklist）
 * `false` = 用 `trustedApplications`（trustlist，语义相反时改这里）
 *
 * 见 LianVpnAbility.buildAppLists() 的说明：SDK 未定义这两个词的语义，
 * 而它们互为反义，选错会让功能正好反过来（关掉的应用反而只走代理）。
 * 已按本工程既有用法（`blockedApplications: [BUNDLE]` 用于排除自身）暂定
 * 为 blocked；真机实测后若需翻转，只改这一行。
 */
const EXCLUDE_VIA_BLOCKED = true;

/** buildAppLists 的返回：已解析好的两个字段与用于日志的计数 */
interface AppListSelection {
  enabled: boolean;
  excludedCount: number;
  blocked: string[];
  trusted: string[];
}

interface ActiveConfig {
  path: string;
  homeDir: string;
}

interface HealthPayload {
  state: string;
  delay: number;
  checkedAt: number;
  detail?: string;
  currentNode: string;
  healthyNodes: number;
  totalNodes: number;
}

interface BridgeStatus {
  running: boolean;
  version: string;
  error: string;
  fd: number;
  configPath: string;
  up: number;
  down: number;
  upTotal: number;
  downTotal: number;
  connections: number;
  proxyConnections: number;
  memory: number;
  mode: string;
  healthState: string;
  healthDelay: number;
  healthCheckedAt: number;
  healthyNodes: number;
  totalNodes: number;
  currentNode: string;
}

/** 写入 core-status.json 的完整结构（桥接字段 + 扩展侧补充的心跳/启动时间） */
interface EnrichedStatus {
  running: boolean;
  version: string;
  error: string;
  fd: number;
  configPath: string;
  up: number;
  down: number;
  upTotal: number;
  downTotal: number;
  connections: number;
  proxyConnections: number;
  memory: number;
  mode: string;
  healthState: string;
  healthDelay: number;
  healthCheckedAt: number;
  healthyNodes: number;
  totalNodes: number;
  currentNode: string;
  recoverCount: number;
  startedAt: number;
  /** 心跳时间戳：主进程据此判断数据是否新鲜、VPN 是否真的在运行 */
  ts: number;
}

/** 主进程写入的模式切换命令 */
interface CoreCommand {
  seq: number;
  mode?: string;
  closeId?: string;
  closeAll?: boolean;
  /** 手动指定的策略组名；为空表示主组 */
  selectGroup?: string;
  /** 手动指定的节点名 */
  selectNode?: string;
  appliedAt?: number;
}

export default class LianVpnAbility extends VpnExtensionAbility {
  private conn?: vpnExtension.VpnConnection;
  private pollTimer: number = -1;
  private lastCommandSeq: number = -1;
  /**
   * 自愈计数（已重建次数，会写入状态文件供界面展示）。
   * 注意：连续失败计数由 Go 侧 coreHealth.failStreak 维护，这里不再重复累计
   * —— 两处都计数会让恢复被推迟约 1 个探测周期。
   */
  private recoverCount: number = 0;
  private lastHealthAt: number = 0;
  private currentTunFd: number = -1;
  private activeConfig?: ActiveConfig;
  private recovering: boolean = false;
  /**
   * 只对“TUN 监听器本身已停止”做有界重建。
   * 普通节点 / DNS / 底层网络失败不得重建系统 TUN，否则会把临时断网
   * 放大成每分钟一次的恢复风暴。一次真实健康探测成功后重置熔断计数。
   */
  private tunRecoverAttempts: number = 0;
  private nextTunRecoverAt: number = 0;

  async onCreate(want: Want): Promise<void> {
    hilog.info(DOMAIN, TAG, 'LianVpnAbility onCreate');
    try {
      const version: string = lianbridge.version();
      hilog.info(DOMAIN, TAG, 'mihomo core loaded, version=%{public}s', version);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'mihomo core load failed: %{public}s', `${err}`);
      return;
    }

    const active = this.resolveActiveConfig(want);
    if (active.path.length === 0) {
      hilog.error(DOMAIN, TAG, 'no generated config path');
      return;
    }
    this.activeConfig = active;

    try {
      const fd: number = await this.createTun();
      this.currentTunFd = fd;
      hilog.info(DOMAIN, TAG, 'tun created fd=%{public}d', fd);
      await this.protectNet();
      hilog.info(DOMAIN, TAG, 'protectProcessNet done');
      const result: string = lianbridge.start(fd, active.path, active.homeDir);
      hilog.info(DOMAIN, TAG, 'core start result=%{public}s', result);
      const status: BridgeStatus = JSON.parse(result) as BridgeStatus;
      const startError: string = status.error ?? '';
      if (startError.length > 0 || !status.running) {
        hilog.error(DOMAIN, TAG, 'core start failed: %{public}s', startError);
        await this.destroyTun();
        return;
      }
      hilog.info(DOMAIN, TAG, 'vpn data plane active fd=%{public}d', fd);
      this.startPolling(active.homeDir);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'vpn start error: %{public}s', JSON.stringify(err));
      await this.destroyTun();
    }
  }

  private resolveActiveConfig(want: Want): ActiveConfig {
    const fallback: ActiveConfig = {
      path: '',
      homeDir: this.context.filesDir + '/lian-core'
    };
    const parameters = (want.parameters ?? {}) as Record<string, string>;
    const wantPath: string = parameters['configPath'] ?? '';
    if (wantPath.length > 0) {
      return {
        path: wantPath,
        homeDir: parameters['homeDir'] ?? fallback.homeDir
      };
    }
    try {
      const raw = fileIo.readTextSync(this.context.filesDir + ACTIVE_CONFIG_FILE);
      const parsed = JSON.parse(raw) as ActiveConfig;
      if (parsed.path.length > 0) {
        return {
          path: parsed.path,
          homeDir: parsed.homeDir.length > 0 ? parsed.homeDir : fallback.homeDir
        };
      }
    } catch (_err) {
      // fall through to empty config
    }
    return fallback;
  }

  private async createTun(): Promise<number> {
    // destroy() 结束的是当前 VpnConnection 的平台网络会话。真机长时测试表明，
    // 在同一对象上 destroy() 后再 create() 会让后续直连 DNS 报 EPERM，
    // protectProcessNet() 也无法稳定恢复。每次都释放旧对象并新建连接，
    // 然后由调用方在启动任何核心 socket 之前重新 protectProcessNet()。
    if (this.conn !== undefined) {
      const previous = this.conn as vpnExtension.VpnConnection;
      try {
        await previous.destroy();
      } catch (_err) {
        // 旧 TUN 可能已由核心关闭，仍然丢弃该连接对象。
      }
      this.conn = undefined;
    }
    const conn = vpnExtension.createVpnConnection(this.context);
    this.conn = conn;
    const addresses: connection.LinkAddress[] = [{
      address: { address: VPN_IP, family: 1 },
      prefixLength: 24
    }];
    const routes: connection.RouteInfo[] = [{
      interface: 'vpn-tun',
      destination: {
        address: { address: '0.0.0.0', family: 1 },
        prefixLength: 0
      },
      gateway: { address: VPN_IP, family: 1 },
      hasGateway: false,
      isDefaultRoute: true
    }];
    const appLists: AppListSelection = this.buildAppLists();
    const config: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      // 系统 DNS 指向 TUN 网关：DNS 查询经 TUN 进入 mihomo 内置 DNS。
      dnsAddresses: [VPN_IP],
      mtu: 1400,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isBlocking: true,
      blockedApplications: appLists.blocked
    };
    // 只下发非空的那一侧。
    // 空数组语义不明确（可能被读成「空名单 = 全部放行」，也可能被读成
    // 「允许列表为空 = 全部不放行」），而两侧同时出现还可能有优先级歧义。
    // 因此另一侧保持 undefined，交由框架用默认值处理。
    if (appLists.trusted.length > 0) {
      config.trustedApplications = appLists.trusted;
    }
    hilog.info(DOMAIN, TAG,
      'vpn config app filter: perApp=%{public}s excluded=%{public}d blocked=%{public}d trusted=%{public}d',
      appLists.enabled ? 'on' : 'off', appLists.excludedCount,
      appLists.blocked.length, appLists.trusted.length);
    return conn.create(config);
  }

  /**
   * 组装 VpnConfig 的应用黑白名单。
   *
   * ## 语义（与 UI 保持一致）
   * 用户可见语义是 FlClash 式：**开关关掉 = 不使用代理（直连）**。
   * 因此「关掉的应用」构成排除集合，对应 `VpnConfig` 的 `blockedApplications`。
   *
   * ## 字段选择依据
   * SDK 文档只写了两个词，未定义语义：
   *   - `trustedApplications` — "The array of trustlist for the VPN network"
   *   - `blockedApplications` — "The array of blocklist for the VPN network"
   *
   * 真机 A/B 验证中，不在 blocked 名单的应用仍持续通过 TUN，而列入名单的
   * 应用被排除。因此这里按 denylist 语义使用 `blockedApplications`。
   *
   * 保留 EXCLUDE_VIA_BLOCKED 单点开关：若平台版本改变语义，改一行即可翻转。
   */
  private buildAppLists(): AppListSelection {
    const filter = AppFilterReader.read(this.context.filesDir);
    if (!filter.enabled) {
      // 未启用分应用代理：仅排除自身，行为与历史版本一致
      return {
        enabled: false,
        excludedCount: 0,
        blocked: [BUNDLE],
        trusted: []
      };
    }
    // 排除集合 + 自身；去重，避免重复包名。
    const excluded: string[] = [BUNDLE];
    for (let i = 0; i < filter.excluded.length; i++) {
      const name = filter.excluded[i];
      if (name !== BUNDLE && excluded.indexOf(name) < 0) {
        excluded.push(name);
      }
    }
    if (EXCLUDE_VIA_BLOCKED) {
      return {
        enabled: true,
        excludedCount: excluded.length,
        blocked: excluded,
        trusted: []
      };
    }
    return {
      enabled: true,
      excludedCount: excluded.length,
      blocked: [],
      trusted: excluded
    };
  }

  private async protectNet(): Promise<void> {
    const conn = this.conn as vpnExtension.VpnConnection;
    try {
      await conn.protectProcessNet();
    } catch (err) {
      throw new Error('protectProcessNet failed: ' + `${err}`);
    }
    hilog.info(DOMAIN, TAG, 'protectProcessNet succeeded');
  }

  private startPolling(homeDir: string): void {
    // 核心启动时刻即“保护开始”时刻，用于首页真实展示已保护时长
    const startedAt: number = Date.now();
    this.pollTimer = setInterval(() => {
      try {
        const raw: string = lianbridge.status();
        const parsed = JSON.parse(raw) as BridgeStatus;
        const enriched: EnrichedStatus = {
          running: parsed.running,
          version: parsed.version,
          error: parsed.error !== undefined && parsed.error !== null ? parsed.error : '',
          fd: parsed.fd,
          configPath: parsed.configPath,
          up: parsed.up,
          down: parsed.down,
          upTotal: parsed.upTotal,
          downTotal: parsed.downTotal,
          connections: parsed.connections,
          proxyConnections: parsed.proxyConnections,
          memory: parsed.memory,
          mode: parsed.mode !== undefined && parsed.mode !== null ? parsed.mode : 'rule',
          healthState: parsed.healthState !== undefined && parsed.healthState !== null ? parsed.healthState : 'unknown',
          healthDelay: parsed.healthDelay !== undefined && parsed.healthDelay !== null ? parsed.healthDelay : 0,
          healthCheckedAt: parsed.healthCheckedAt !== undefined && parsed.healthCheckedAt !== null ? parsed.healthCheckedAt : 0,
          healthyNodes: parsed.healthyNodes !== undefined && parsed.healthyNodes !== null ? parsed.healthyNodes : 0,
          totalNodes: parsed.totalNodes !== undefined && parsed.totalNodes !== null ? parsed.totalNodes : 0,
          currentNode: parsed.currentNode !== undefined && parsed.currentNode !== null ? parsed.currentNode : '',
          recoverCount: this.recoverCount,
          startedAt: startedAt,
          ts: Date.now()
        };
        this.writeTextFileSync(homeDir + '/core-status.json', JSON.stringify(enriched));
        // 真实连接明细（供“实时连接”页面）
        this.writeTextFileSync(homeDir + '/core-connections.json', lianbridge.connections());
        // 链路健康探测 + 自愈（每 30 秒一次，扩展进程在后台不会被冻结）
        this.tickHealthWatchdog(parsed, homeDir);
      } catch (_err) {
        // status file is advisory
      }
      this.applyPendingCommand(homeDir);
    }, 1000);
  }

  /**
   * 链路看门狗：每 30 秒对真实出口做一次 URL 探测。
   * 连续两次失败判定为链路失效，重建核心（自愈），解决长时间运行后节点失效/凭据过期导致的静默掉线。
   */
  private tickHealthWatchdog(parsed: BridgeStatus, homeDir: string): void {
    if (!parsed.running) {
      return;
    }
    const now: number = Date.now();
    const intervalMs: number = 30000;
    if (this.lastHealthAt > 0 && now - this.lastHealthAt < intervalMs) {
      return;
    }
    this.lastHealthAt = now;
    let payload: HealthPayload | undefined = undefined;
    try {
      const raw: string = lianbridge.health();
      payload = JSON.parse(raw) as HealthPayload;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'health probe failed: %{public}s', `${err}`);
      return;
    }
    if (payload === undefined) {
      return;
    }
    if (payload.state === 'ok') {
      this.tunRecoverAttempts = 0;
      this.nextTunRecoverAt = 0;
      hilog.info(DOMAIN, TAG, 'tunnel healthy delay=%{public}dms node=%{public}s',
        payload.delay, payload.currentNode);
      return;
    }
    // 只有明确判定为 fail 才自愈。
    //
    // 这里必须用「白名单」语义（只认 fail），不能用 `!== 'ok'`：
    // Go 侧 coreHealth.state 的初值是 'unknown'，且每次 stop 时
    // resetCoreHealth() 也会把它重置为 'unknown'。若把 unknown 当作故障，
    // 启动瞬间与每次重建后都会立刻再触发一次重建，形成自愈风暴
    // （实测 recoverCount 在 10 小时内累积到 194 次，约每 3 分钟一次）。
    if (payload.state !== 'fail') {
      return;
    }
    const detail: string = payload.detail !== undefined ? payload.detail : '';
    // 节点超时、DNS 失败、Wi-Fi/蜂窝网切换都是上游网络故障：
    // 重建系统 TUN 无法修复它们，反而会撤销当前的进程网络保护。
    // 只有 Go 核心明确报告 TUN listener 已停止时才重建平台 TUN。
    if (detail !== 'tun listener disabled') {
      hilog.warn(DOMAIN, TAG,
        'tunnel unhealthy (confirmed) detail=%{public}s; keep tun and wait for network recovery',
        detail);
      return;
    }
    if (now < this.nextTunRecoverAt) {
      hilog.warn(DOMAIN, TAG, 'tun recovery deferred until=%{public}d detail=%{public}s',
        this.nextTunRecoverAt, detail);
      return;
    }
    if (this.tunRecoverAttempts >= TUN_RECOVER_MAX_ATTEMPTS) {
      hilog.error(DOMAIN, TAG, 'tun recovery circuit open attempts=%{public}d',
        this.tunRecoverAttempts);
      return;
    }
    this.tunRecoverAttempts++;
    const delayMultiplier: number = this.tunRecoverAttempts === 1 ? 1 :
      (this.tunRecoverAttempts === 2 ? 2 : 4);
    this.nextTunRecoverAt = now + TUN_RECOVER_BASE_DELAY_MS * delayMultiplier;
    hilog.warn(DOMAIN, TAG, 'tun listener disabled; recovering attempt=%{public}d',
      this.tunRecoverAttempts);
    this.recoverCore().catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'core recover promise failed: %{public}s', `${err}`);
    });
  }

  /**
   * 自愈：重建系统 TUN，再按当前配置启动核心。
   *
   * OpenHarmony 下 VpnConnection.create() 返回的是平台特殊描述符；
   * 真机 A/B 证明 dup(2) 出来的副本会让原生浏览器的 TCP 连接卡在
   * ERR_SOCKET_NOT_CONNECTED。因此核心直接使用原 fd；核心 stop 后
   * 该 fd 已被 sing-tun 关闭，绝不能复用，必须让系统创建新 TUN。
   */
  private async recoverCore(): Promise<void> {
    const active: ActiveConfig | undefined = this.activeConfig;
    if (active === undefined || active.path.length === 0 || this.recovering) {
      return;
    }
    this.recovering = true;
    try {
      hilog.warn(DOMAIN, TAG, 'recovering core, attempt=%{public}d', this.recoverCount + 1);
      let selectedNode: string = '';
      try {
        const before = JSON.parse(lianbridge.status()) as BridgeStatus;
        selectedNode = before.currentNode ?? '';
      } catch (_err) {
        // 节点恢复是增强项，不得阻断 TUN 自愈。
      }
      lianbridge.stop();
      this.currentTunFd = -1;
      const fd: number = await this.createTun();
      this.currentTunFd = fd;
      await this.protectNet();
      const result: string = lianbridge.start(fd, active.path, active.homeDir);
      const status = JSON.parse(result) as BridgeStatus;
      if (status.running) {
        if (selectedNode.length > 0) {
          lianbridge.selectNode(MANUAL_GROUP_NAME, selectedNode);
        }
        this.recoverCount++;
        hilog.info(DOMAIN, TAG, 'core recovered with fresh tun fd=%{public}d count=%{public}d',
          fd, this.recoverCount);
      } else {
        hilog.error(DOMAIN, TAG, 'core recover failed: %{public}s', status.error);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'core recover error: %{public}s', `${err}`);
    } finally {
      this.recovering = false;
    }
  }

  /** 读取主进程写入的模式切换命令并热应用（无需重连） */
  private applyPendingCommand(homeDir: string): void {
    try {
      const raw: string = fileIo.readTextSync(homeDir + '/core-command.json');
      if (raw.length === 0) {
        return;
      }
      const cmd = JSON.parse(raw) as CoreCommand;
      if (cmd.seq === this.lastCommandSeq) {
        return;
      }
      this.lastCommandSeq = cmd.seq;
      if (cmd.mode !== undefined && cmd.mode !== null && cmd.mode.length > 0) {
        const result: string = lianbridge.setMode(cmd.mode);
        hilog.info(DOMAIN, TAG, 'outbound mode applied: %{public}s', cmd.mode);
        if (result.length > 0) {
          this.writeTextFileSync(homeDir + '/core-status.json', result);
        }
      }
      if (cmd.selectNode !== undefined && cmd.selectNode !== null &&
        cmd.selectNode.length > 0) {
        // 手动指定出口节点。传空组名时核心会作用于主组。
        const group: string = cmd.selectGroup !== undefined && cmd.selectGroup !== null
          ? cmd.selectGroup : '';
        const result: string = lianbridge.selectNode(group, cmd.selectNode);
        hilog.info(DOMAIN, TAG, 'node selection applied: group=%{public}s name=%{public}s',
          group.length > 0 ? group : '(main)', cmd.selectNode);
        if (result.length > 0) {
          this.writeTextFileSync(homeDir + '/core-status.json', result);
        }
      }
      if (cmd.closeAll === true) {
        lianbridge.closeConnection('');
        hilog.info(DOMAIN, TAG, 'all connections closed by user');
      } else if (cmd.closeId !== undefined && cmd.closeId !== null && cmd.closeId.length > 0) {
        lianbridge.closeConnection(cmd.closeId);
        hilog.info(DOMAIN, TAG, 'connection closed by user');
      }
      const ack: CoreCommand = { seq: cmd.seq, appliedAt: Date.now() };
      this.writeTextFileSync(homeDir + '/core-command.json', JSON.stringify(ack));
    } catch (_err) {
      // 命令文件不存在属正常情况
    }
  }

  /**
   * 原子写入：先写临时文件再 rename 覆盖目标文件。
   * 读取方（主进程每秒轮询）不会读到被 TRUNC 后的半截内容。
   */
  private writeTextFileSync(path: string, content: string): void {
    const tmpPath: string = path + '.tmp';
    let fd = -1;
    try {
      const f = fileIo.openSync(tmpPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fd = f.fd;
      fileIo.writeSync(fd, content);
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (_err) {
        }
      }
    }
    try {
      fileIo.renameSync(tmpPath, path);
    } catch (_err) {
      // rename 不被允许时退回直接写入，保证仍有数据可读
      let directFd = -1;
      try {
        const f2 = fileIo.openSync(path,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
        directFd = f2.fd;
        fileIo.writeSync(directFd, content);
      } catch (_err2) {
      } finally {
        if (directFd >= 0) {
          try {
            fileIo.closeSync(directFd);
          } catch (_err3) {
          }
        }
      }
    }
  }

  private async destroyTun(): Promise<void> {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    try {
      lianbridge.stop();
      hilog.info(DOMAIN, TAG, 'mihomo core stop completed');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'mihomo core stop failed: %{public}s', `${err}`);
    }
    if (this.conn !== undefined) {
      const conn = this.conn as vpnExtension.VpnConnection;
      try {
        await conn.destroy();
        hilog.info(DOMAIN, TAG, 'vpn connection destroy completed');
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'vpn connection destroy failed: %{public}s', `${err}`);
      }
      this.conn = undefined;
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'LianVpnAbility onDestroy');
    this.destroyTun().then(() => {
      hilog.info(DOMAIN, TAG, 'vpn tunnel cleanup completed');
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'vpn tunnel cleanup failed: %{public}s', `${err}`);
    });
  }
}
