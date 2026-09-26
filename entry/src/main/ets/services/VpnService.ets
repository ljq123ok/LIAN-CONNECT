import { connection, vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import Want from '@ohos.app.ability.Want';
import { VpnState } from '../models/ArkModels';
import { hilog } from '@kit.PerformanceAnalysisKit';

const VPN_BUNDLE = 'com.lianconnect.app';
const VPN_ABILITY = 'LianVpnAbility';
const DOMAIN = 0x2020;
const TAG = 'LianVpnSvc';

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
      hilog.warn(DOMAIN, TAG, 'system vpn state refresh failed: %{public}s', `${err}`);
    }
    return this.state;
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

      // startVpnExtensionAbility resolves when the extension is launched, not
      // when mihomo has successfully attached the TUN fd. Give the extension
      // a short settling window, then require a real system VPN bearer. This
      // prevents a failed core from being shown as a false connected state.
      await new Promise<void>((resolve) => setTimeout(resolve, 700));
      if (!await this.isSystemVpnActive()) {
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
