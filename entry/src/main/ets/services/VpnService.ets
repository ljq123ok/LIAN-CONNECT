import { connection, vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import Want from '@ohos.app.ability.Want';
import fileIo from '@ohos.file.fs';
import { VpnState } from '../models/ArkModels';
import { hilog } from '@kit.PerformanceAnalysisKit';

const VPN_BUNDLE = 'com.lianconnect.app';
const VPN_ABILITY = 'LianVpnAbility';
const DOMAIN = 0x2020;
const TAG = 'LianVpnSvc';
/** 等待核心真正挂上 TUN 的上限（毫秒） */
const CORE_READY_TIMEOUT_MS = 6000;
/** 轮询核心状态文件的间隔（毫秒） */
const CORE_READY_POLL_MS = 150;
/** 心跳超过该毫秒数即视为陈旧 */
const CORE_HEARTBEAT_FRESH_MS = 6000;

/** 核心状态文件里判定「已就绪」所需的最小子集 */
interface CoreProbe {
  running?: boolean;
  ts?: number;
}

export interface VpnStartResult {
  success: boolean;
  error?: string;
}

export class VpnService {
  private state: VpnState = 'idle';
  private lastError: string = '';

  getState(): VpnState {
    return this.state;
  }

  getLastError(): string {
    return this.lastError;
  }

  /**
   * 系统层是否仍有 VPN bearer。
   *
   * 为什么需要它：读核心心跳文件来判断连接状态并不可靠 ——
   * 锁屏/后台时扩展的 JS 定时器可能被挂起，心跳随之中断，但**隧道
   * 本身仍在工作**。系统 bearer 查询不受 JS 定时器影响，因此
   * 用它复核可以避免「因为心跳迟到就去重建一条完好的隧道」。
   */
  async isSystemVpnActive(): Promise<boolean> {
    const networks = await connection.getAllNets();
    for (let i = 0; i < networks.length; i++) {
      const capabilities = await connection.getNetCapabilities(networks[i]);
      if (capabilities.bearerTypes.indexOf(connection.NetBearType.BEARER_VPN) >= 0) {
        return true;
      }
    }
    return false;
  }

  async refreshState(): Promise<VpnState> {
    if (this.state === 'connecting' || this.state === 'stopping') {
      return this.state;
    }
    try {
      this.state = await this.isSystemVpnActive() ? 'connected' : 'idle';
      hilog.info(DOMAIN, TAG, 'system vpn state refreshed: %{public}s', this.state);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'system vpn state refresh failed');
    }
    return this.state;
  }

  /**
   * 等待核心真正挂上 TUN（心跳变成 running=true 且新鲜）。
   *
   * 为什么要等：系统 VPN 承载由扩展的 VpnConnection.create() 建立，它会
   * 比 mihomo 真正接管 TUN 早约 1 秒出现。真机日志里因此出现过
   * 「data plane active」与「LianVpnAbility onDestroy」落在同一毫秒的错乱 ——
   * 用户在那一秒内再点一次，就会对还在启动中的核心下发停止。
   * 只看 bearer 还会把「扩展起来了但核心启动失败」当成连接成功。
   *
   * @returns 核心是否在超时前真正进入运行状态
   */
  private async waitForCoreReady(homeDir: string): Promise<boolean> {
    if (homeDir.length === 0) {
      return false;
    }
    const statusPath: string = homeDir + '/core-status.json';
    const deadline: number = Date.now() + CORE_READY_TIMEOUT_MS;
    while (Date.now() < deadline) {
      try {
        const raw: string = fileIo.readTextSync(statusPath);
        if (raw.length > 0) {
          const parsed = JSON.parse(raw) as CoreProbe;
          const running: boolean = parsed.running === true;
          const ts: number = parsed.ts !== undefined && parsed.ts !== null ? parsed.ts : 0;
          const fresh: boolean = ts > 0 && (Date.now() - ts) < CORE_HEARTBEAT_FRESH_MS;
          if (running && fresh) {
            return true;
          }
        }
      } catch (_err) {
        // 状态文件尚未写出属正常情况，继续等待
      }
      await new Promise<void>((resolve) => setTimeout(resolve, CORE_READY_POLL_MS));
    }
    return false;
  }

  private buildWant(): Want {
    return {
      bundleName: VPN_BUNDLE,
      abilityName: VPN_ABILITY
    };
  }

  private formatError(code: number, message: string): string {
    if (code === 2203001) {
      return 'VPN 授权被拒绝或已有其他 VPN 正在运行';
    }
    if (code === 2203002) {
      return 'VPN 扩展已存在，请先停止';
    }
    return message + ' (code: ' + code + ')';
  }

  async start(configPath: string = '', homeDir: string = ''): Promise<VpnStartResult> {
    if (this.state === 'connecting' || this.state === 'connected') {
      // state 只是本对象的缓存，可能与真实系统状态脱节：核心异常退出时
      // 没有任何路径把它重置（refreshState 目前无人调用），于是它会永久停在
      // 'connected'，导致此后每次 start() 都在这里提前返回失败 —— 表现为
      // 「点了没反应，再点一次才好」。
      // 因此这里以系统 bearer 为准复核一次，只有确实仍有 VPN 在跑才拒绝。
      const reallyConnected: boolean = await this.isSystemVpnActive();
      if (reallyConnected) {
        return { success: false, error: 'VPN 正在启动或已连接' };
      }
      hilog.info(DOMAIN, TAG, 'state was %{public}s but no system vpn; resuming start', this.state);
      this.state = 'idle';
    }
    this.state = 'connecting';
    this.lastError = '';
    try {
      hilog.info(DOMAIN, TAG, 'requesting vpn extension start');
      await vpnExtension.startVpnExtensionAbility(this.buildWant());
      hilog.info(DOMAIN, TAG, 'vpn extension start resolved');

      // startVpnExtensionAbility 只保证扩展被拉起，不保证 mihomo 已接管 TUN。
      // 因此先确认系统 bearer 已建立（挡住扩展根本没起来的情况），
      // 再等核心真正进入运行状态（挡住「扩展起来了但核心启动失败」，
      // 以及 bearer 早于数据面出现导致的秒级竞态）。
      if (!await this.isSystemVpnActive()) {
        await new Promise<void>((resolve) => setTimeout(resolve, 700));
      }
      if (!await this.isSystemVpnActive()) {
        this.lastError = 'VPN 扩展启动失败，请检查系统日志';
        this.state = 'error';
        return { success: false, error: this.lastError };
      }
      const coreReady: boolean = await this.waitForCoreReady(homeDir);
      if (!coreReady) {
        this.lastError = 'VPN 核心启动失败，请检查节点或系统日志';
        this.state = 'error';
        return { success: false, error: this.lastError };
      }
      this.state = 'connected';
      return { success: true };
    } catch (err) {
      const error = err as BusinessError;
      this.lastError = this.formatError(error.code, error.message);
      this.state = 'error';
      return { success: false, error: this.lastError };
    }
  }

  async stop(): Promise<VpnStartResult> {
    if (this.state === 'stopping') {
      return { success: false, error: 'VPN 正在停止' };
    }
    this.state = 'stopping';
    this.lastError = '';
    try {
      hilog.info(DOMAIN, TAG, 'requesting vpn extension stop');
      await vpnExtension.stopVpnExtensionAbility(this.buildWant());
      hilog.info(DOMAIN, TAG, 'vpn extension stop resolved');
      this.state = 'idle';
      return { success: true };
    } catch (err) {
      const error = err as BusinessError;
      this.lastError = this.formatError(error.code, error.message);
      this.state = 'error';
      return { success: false, error: this.lastError };
    }
  }
}
