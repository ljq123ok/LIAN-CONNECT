import {
  AppConnection,
  DnsServer,
  ProxyGroup,
  RecoveryEvent,
  RuleItem
} from '../models/ArkModels';

export class MockData {
  static nodeGroups(): ProxyGroup[] {
    const groups: ProxyGroup[] = [];
    groups.push({
      name: '自动选择',
      type: '策略组',
      nodes: [
        { name: '香港 HK-01', protocol: 'Shadowsocks', group: '自动选择', latency: 122, selected: true },
        { name: '日本 JP-01', protocol: 'VMess', group: '自动选择', latency: 156, selected: false },
        { name: '新加坡 SG-01', protocol: 'Trojan', group: '自动选择', latency: 143, selected: false }
      ]
    });
    groups.push({
      name: '香港',
      type: '节点组',
      nodes: [
        { name: '香港 HK-02', protocol: 'Shadowsocks', group: '香港', latency: 131, selected: false },
        { name: '香港 HK-03', protocol: 'VMess', group: '香港', latency: 118, selected: false },
        { name: '香港 HK-04', protocol: 'Hysteria2', group: '香港', latency: -1, selected: false }
      ]
    });
    groups.push({
      name: '日本',
      type: '节点组',
      nodes: [
        { name: '日本 JP-02', protocol: 'Trojan', group: '日本', latency: 168, selected: false },
        { name: '日本 JP-03', protocol: 'VLESS', group: '日本', latency: 174, selected: false }
      ]
    });
    groups.push({
      name: '美国',
      type: '节点组',
      nodes: [
        { name: '美国 US-01', protocol: 'VMess', group: '美国', latency: 242, selected: false },
        { name: '美国 US-02', protocol: 'TUIC', group: '美国', latency: 231, selected: false }
      ]
    });
    return groups;
  }

  static connections(): AppConnection[] {
    const rows: AppConnection[] = [];
    rows.push({
      id: 'c1',
      host: 'api.openai.com',
      app: 'ChatGPT',
      rule: 'MATCH',
      proxy: '香港 HK-01',
      down: '1.24 MB',
      up: '86 KB',
      time: '02:14:09'
    });
    rows.push({
      id: 'c2',
      host: 'tile-service.openstreetmap.org',
      app: '地图',
      rule: 'DOMAIN-SUFFIX',
      proxy: '香港 HK-01',
      down: '684 KB',
      up: '32 KB',
      time: '02:11:44'
    });
    rows.push({
      id: 'c3',
      host: 'push.apple.com',
      app: '系统服务',
      rule: 'DOMAIN-KEYWORD',
      proxy: 'DIRECT',
      down: '38 KB',
      up: '9 KB',
      time: '02:08:22'
    });
    rows.push({
      id: 'c4',
      host: 'cdn.example.com',
      app: '浏览器',
      rule: 'GEOSITE',
      proxy: 'DIRECT',
      down: '8.2 MB',
      up: '1.1 MB',
      time: '02:03:17'
    });
    return rows;
  }

  static rules(): RuleItem[] {
    const rows: RuleItem[] = [];
    rows.push({ type: 'DOMAIN-SUFFIX', payload: 'googleapis.com', proxy: '香港 HK-01' });
    rows.push({ type: 'DOMAIN-SUFFIX', payload: 'telegram.org', proxy: '香港 HK-01' });
    rows.push({ type: 'DOMAIN-KEYWORD', payload: 'openai', proxy: '香港 HK-01' });
    rows.push({ type: 'IP-CIDR', payload: '10.0.0.0/8', proxy: 'DIRECT' });
    rows.push({ type: 'IP-CIDR', payload: '192.168.0.0/16', proxy: 'DIRECT' });
    rows.push({ type: 'GEOSITE', payload: 'cn', proxy: 'DIRECT' });
    rows.push({ type: 'DOMAIN-SUFFIX', payload: 'bilibili.com', proxy: 'DIRECT' });
    rows.push({ type: 'MATCH', payload: '', proxy: '香港 HK-01' });
    return rows;
  }

  static events(): RecoveryEvent[] {
    const rows: RecoveryEvent[] = [];
    rows.push({
      time: '10:31:22',
      title: '网络从 Wi-Fi 切换到蜂窝',
      desc: 'NetHandle 已更新，TUN 保留',
      type: 'ok'
    });
    rows.push({
      time: '10:31:23',
      title: '出站连接重建失败',
      desc: 'TLS handshake timeout',
      type: 'warn'
    });
    rows.push({
      time: '10:31:25',
      title: '已切换到备用节点',
      desc: '香港 HK-01 → 香港 HK-02',
      type: 'warn'
    });
    rows.push({
      time: '10:31:26',
      title: 'VPN 恢复成功',
      desc: '连接建立耗时 1.8s',
      type: 'ok'
    });
    return rows;
  }

  static dnsServers(): DnsServer[] {
    const rows: DnsServer[] = [];
    rows.push({
      name: '远端 DoH',
      address: 'https://dns.google/dns-query',
      latency: '42 ms',
      kind: 'HTTPS'
    });
    rows.push({
      name: '国内 DNS',
      address: 'https://223.5.5.5/dns-query',
      latency: '18 ms',
      kind: 'HTTPS'
    });
    rows.push({
      name: 'Bootstrap',
      address: '223.5.5.5',
      latency: '12 ms',
      kind: 'UDP'
    });
    return rows;
  }
}
