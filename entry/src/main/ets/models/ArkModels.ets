export interface ProxyNode {
  name: string;
  protocol: string;
  group: string;
  latency: number;
  selected: boolean;
  link?: string;
}

export interface ProxyGroup {
  name: string;
  type: string;
  nodes: ProxyNode[];
}

export interface AppConnection {
  id: string;
  host: string;
  app: string;
  rule: string;
  proxy: string;
  down: string;
  up: string;
  time: string;
}

export interface RuleItem {
  type: string;
  payload: string;
  proxy: string;
}

export interface RecoveryEvent {
  time: string;
  title: string;
  desc: string;
  type: string;
}

export interface DnsServer {
  name: string;
  address: string;
  latency: string;
  kind: string;
}

export interface SubscriptionProfile {
  id: string;
  name: string;
  sourceUrl: string;
  detectedFormat: string;
  nodeCount: number;
  updatedAt: string;
  active: boolean;
  content: string;
}

export interface ImportResult {
  ok: boolean;
  message: string;
  format: string;
  nodeCount: number;
  nodes: ProxyNode[];
  content: string;
}

export interface GeneratedConfig {
  path: string;
  controllerUrl: string;
  mixedPort: number;
  timestamp: string;
}

export interface AppSettings {
  autoConnect: boolean;
  networkRecover: boolean;
  screenKeep: boolean;
  failClosed: boolean;
  notificationOn: boolean;
  dnsMode: string;
  dnsCache: boolean;
  fakeIp: boolean;
  sniff: boolean;
  proxyMode: string;
  logLevel: string;
  testUrl: string;
  /** 分应用代理：关闭时不启用；黑名单语义见 PROXY_EXCLUDED_APPS */
  perAppProxyEnabled: boolean;
}

/**
 * 分应用代理的开关状态。
 * 语义与 FlClash 一致：**关 = 不使用代理（直连），开 = 使用代理**。
 * 因此「黑名单」= 那些被关掉的包名集合，持久化时只存被关掉的。
 */
export interface AppProxyRule {
  bundleName: string;
  appName: string;
  /** true = 走代理；false = 直连（不使用代理） */
  proxied: boolean;
}

export type VpnState = 'idle' | 'connecting' | 'connected' | 'stopping' | 'error';
