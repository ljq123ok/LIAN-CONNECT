import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { buffer, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x2021;
const TAG = 'LatencyTester';

export interface LinkEndpoint {
  host: string;
  port: number;
}

/**
 * 解析各协议分享链接，提取 server host:port。
 * 支持 ss / vmess / vless / trojan / hysteria2 / tuic。
 */
export class LatencyTester {
  /**
   * 从单节点链接解析 host:port。
   * @returns 解析失败返回 null
   */
  static endpointOf(link: string): LinkEndpoint | null {
    try {
      if (link.startsWith('vmess://')) {
        return LatencyTester.vmessEndpoint(link);
      }
      if (link.startsWith('ss://')) {
        return LatencyTester.authorityEndpoint(link.substring('ss://'.length));
      }
      if (link.startsWith('trojan://')) {
        return LatencyTester.authorityEndpoint(link.substring('trojan://'.length));
      }
      if (link.startsWith('vless://')) {
        return LatencyTester.authorityEndpoint(link.substring('vless://'.length));
      }
      if (link.startsWith('hysteria2://') || link.startsWith('hy2://')) {
        const rest = link.startsWith('hysteria2://') ? link.substring('hysteria2://'.length) : link.substring('hy2://'.length);
        return LatencyTester.authorityEndpoint(rest);
      }
      if (link.startsWith('tuic://')) {
        return LatencyTester.authorityEndpoint(link.substring('tuic://'.length));
      }
      return null;
    } catch (_err) {
      return null;
    }
  }

  private static vmessEndpoint(link: string): LinkEndpoint | null {
    const payload = link.substring('vmess://'.length);
    const hashIdx = payload.indexOf('#');
    const base64 = hashIdx >= 0 ? payload.substring(0, hashIdx) : payload;
    try {
      const bytes = new util.Base64Helper().decodeSync(base64);
      const jsonText = buffer.from(bytes).toString('utf8');
      const obj = JSON.parse(jsonText) as Record<string, string>;
      const add = obj['add'];
      const portStr = obj['port'];
      if (add === undefined || portStr === undefined) {
        return null;
      }
      const port = Number.parseInt(portStr, 10);
      if (Number.isNaN(port) || port <= 0) {
        return null;
      }
      return { host: add, port: port };
    } catch (_err) {
      return null;
    }
  }

  /**
   * 解析 user:pass@host:port#name 形式，兼容 ss 的 base64 整体或 host:port。
   */
  private static authorityEndpoint(authority: string): LinkEndpoint | null {
    // 去掉 # 后的名字
    const hashIdx = authority.indexOf('#');
    const rest = hashIdx >= 0 ? authority.substring(0, hashIdx) : authority;
    // ss:// 可能整体 base64：base64(user:pass@host:port)
    let hostPart = rest;
    if (rest.indexOf('@') < 0 && rest.indexOf('/') < 0) {
      // 尝试 base64 解码（ss 的 SIP002 是 base64(方法:密码)@host:port；裸 base64 是整体）
      const decoded = LatencyTester.tryBase64(rest);
      if (decoded.length > 0) {
        hostPart = decoded;
      }
    }
    const atIdx = hostPart.lastIndexOf('@');
    if (atIdx >= 0) {
      hostPart = hostPart.substring(atIdx + 1);
    }
    // hostPart 可能是 host:port 或 host:port/参数
    const slashIdx = hostPart.indexOf('/');
    if (slashIdx >= 0) {
      hostPart = hostPart.substring(0, slashIdx);
    }
    const colonIdx = hostPart.lastIndexOf(':');
    if (colonIdx < 0) {
      return null;
    }
    const host = hostPart.substring(0, colonIdx).trim();
    const portStr = hostPart.substring(colonIdx + 1).trim();
    const port = Number.parseInt(portStr, 10);
    if (host.length === 0 || Number.isNaN(port) || port <= 0) {
      return null;
    }
    return { host: host, port: port };
  }

  private static tryBase64(content: string): string {
    try {
      const bytes = new util.Base64Helper().decodeSync(content);
      return buffer.from(bytes).toString('utf8');
    } catch (_err) {
      return '';
    }
  }

  /**
   * 对节点做真实 TCP connect 测速。
   * @param link 节点分享链接
   * @param timeoutMs 连接超时（默认 3000ms）
   * @returns 延迟毫秒数；失败返回 -1
   */
  static async test(link: string, timeoutMs: number = 3000): Promise<number> {
    const ep = LatencyTester.endpointOf(link);
    if (ep === null) {
      return -1;
    }
    return LatencyTester.testHost(ep.host, ep.port, timeoutMs);
  }

  /** 对任意 host:port 做真实 TCP 连接测速（用于 DNS 上游等连通性检查） */
  static async testHost(host: string, port: number, timeoutMs: number = 3000): Promise<number> {
    if (host.length === 0 || port <= 0) {
      return -1;
    }
    const tcp = socket.constructTCPSocketInstance();
    const started = Date.now();
    try {
      await tcp.connect({
        address: { address: host, port: port, family: 1 },
        timeout: timeoutMs
      });
      const cost = Date.now() - started;
      try {
        await tcp.close();
      } catch (_err) {
      }
      return cost;
    } catch (err) {
      const e = err as BusinessError;
      hilog.info(DOMAIN, TAG, 'connect fail host=%{public}s err=%{public}s', host, e.message ?? '');
      try {
        await tcp.close();
      } catch (_err) {
      }
      return -1;
    }
  }
}
