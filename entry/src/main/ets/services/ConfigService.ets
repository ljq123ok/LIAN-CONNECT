import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import fileIo from '@ohos.file.fs';
import { buffer, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DnsServer, GeneratedConfig, ProxyNode, RuleItem, SubscriptionProfile } from '../models/ArkModels';
import { SubscriptionService } from './SubscriptionService';
import { GeoAssets } from './GeoAssets';

const LOCAL_MIXED_PORT = 7890;
const CFG_DOMAIN = 0x2024;
const CFG_TAG = 'ConfigSvc';
const LOCAL_CONTROLLER = '127.0.0.1:9090';
const CONFIG_DIR = '/generated';
const CONFIG_FILE = '/config.yaml';
const PREF_NAME = 'lian_config';
const KEY_GENERATED = 'generated_config';
/** 分享链接路径下由本应用生成的策略组名（规则与 DNS 出口标记共用） */
const AUTO_SELECT_GROUP = '自动选择';
/**
 * AI/ChatGPT 专用出口组：只含美国节点。
 *
 * ## 为什么必须限定地区
 * 实测（HarmonyOS 7 真机）：`AUTO_SELECT_GROUP` 是覆盖全部节点的
 * url-test，曾选中卡塔尔出口（`loc=QA, colo=DOH`），而 **OpenAI 不支持该地区**，
 * 服务端直接返回 403（Cloudflare 托管挑战），表现为「ChatGPT 连不上」
 * 而其它应用一切正常。因此 AI 流量必须固定走 OpenAI 支持的地区。
 *
 * ## 为什么用 filter 而不是把节点名列成清单
 * 订阅节点会变（增删/改名），写死清单会在下次更新后失效。
 * `include-all-proxies` + `filter` 让 mihomo 按名字在运行时筛选，
 * 订阅更新后自动跟随。
 *
 * ## 判据
 * 三个独立判据在真实订阅上结果一致（均命中 32 个节点、零误报）：
 * 国旗 emoji 🇺🇸 / 中文「美国」/ 独立单词 US。
 * 用「或」组合以兼容不同订阅的命名习惯。
 */
/**
 * 「手动选择」组：包住自动测速组，让用户的选择真正生效。
 *
 * ## 为什么需要它
 * mihomo 的 url-test 组**不尊重手动选择**：它的 DialContext 每次都调
 * `fast(true)` 重新测速选点（见 adapter/outboundgroup/urltest.go），
 * 因此对 url-test 调 Set() 会被下一轮测速覆盖 —— 表现为「界面选了
 * 日本节点，实际出口却仍是卡塔尔等自动选出的地区」。
 * 而 select 组使用 `selected` 字段（selector.go:selectedProxy），
 * 手动指定的出口会稳定保持。
 *
 * ## 结构
 *   <AUTO_SELECT_GROUP>            url-test，成员=全部节点（自动择优，默认）
 *   <MANUAL_GROUP>                 select，成员=自动选择 + 各节点（手动指定）
 * 规则（含 MATCH）统一指向 MANUAL_GROUP，其默认值仍是 url-test 组，
 * 因此不手动干预时行为与之前完全一致。
 */
const MANUAL_GROUP = '手动选择';

/**
 * 默认延迟测试地址。
 *
 * 用于策略组的 url-test：mihomo 周期性用它测每个节点，据此挑选出口。
 * 必须是「任何地区、任何节点都能返回同一状态码」的轻量地址：
 *  - gstatic/google 的 generate_204 固定返回 204，且国内可直连，
 *    不会因为某节点无法访问某个站点就被误判为失效；
 *  - 反例是 chatgpt.com（返回 403）或 api.openai.com（返回 401），
 *    若不加 expected-status，全部节点都会被判失败，组内将无可用节点。
 *
 * 可在设置页「延迟测试地址」覆盖，该值经 generate() 的 testUrl 参数生效。
 */
const DEFAULT_TEST_URL = 'https://www.gstatic.com/generate_204';
const SECTION_KEYS: string[] = [
  'proxies:', 'proxy-groups:', 'rules:', 'proxy-providers:', 'rule-providers:'
];

interface ShareNode {
  server: string;
  port: string;
  password: string;
  uuid: string;
  network: string;
  tls: string;
  /**
   * REALITY 参数（对应 mihomo 的 `reality-opts`）。
   *
   * 实测：订阅里的 vless 节点大量使用 `security=reality`，若只发
   * `tls: true` 而丢掉 pbk/sid，服务端按 TLS 握手、客户端按 VLESS 解析，
   * 会得到 `unexpected response version`（见 transport/vless/conn.go:131），
   * 表现为「切换订阅后所有外网都不通」。
   */
  sni: string;
  flow: string;
  fingerprint: string;
  realityPublicKey: string;
  realityShortId: string;
  /** 是否跳过证书校验（`insecure=1`） */
  insecure: boolean;
}

export class ConfigService {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  generate(profile: SubscriptionProfile, subService: SubscriptionService,
    selectedNodeName: string = '', proxyMode: string = '规则',
    testUrl: string = ''): GeneratedConfig {
    // 归一化测试地址：空值或非法值一律退回默认，避免把坏 URL 写进配置
    // 导致所有节点测速失败（那会让 url-test 组内无可用节点）。
    const trimmedTest: string = testUrl !== undefined && testUrl !== null ? testUrl.trim() : '';
    this.testUrlForGroups = this.isValidTestUrl(trimmedTest) ? trimmedTest : DEFAULT_TEST_URL;
    const content = subService.loadContent(profile.id);
    if (content.length === 0) {
      throw new Error('订阅内容为空');
    }
    const result = subService.analyzeContent(content);
    if (!result.ok) {
      throw new Error(result.message);
    }
    const mode: string = this.mihomoMode(proxyMode);
    // 内置 geo 规则数据落地（决定能否用 GEOSITE/GEOIP 做国内分流）
    const homeDir = this.context.filesDir + '/lian-core';
    this.ensureDir(homeDir);
    const geoReady: boolean = GeoAssets.ensure(this.context, homeDir);
    let output = '';
    if (profile.detectedFormat === 'clash-yaml') {
      output = this.buildPreservedYaml(content, mode, geoReady);
    } else if (profile.detectedFormat === 'base64-links' || profile.detectedFormat === 'share-links') {
      output = this.buildConvertedYaml(result.nodes, selectedNodeName, mode, geoReady);
    } else {
      throw new Error('不支持的配置格式');
    }
    const path = this.writeConfig(output);
    hilog.info(CFG_DOMAIN, CFG_TAG,
      'generated config path=%{public}s format=%{public}s nodes=%{public}d mode=%{public}s geo=%{public}s dns=%{public}s',
      path, profile.detectedFormat, result.nodes.length, mode,
      geoReady ? 'geosite+geoip' : 'builtin-domain-list',
      output.indexOf('\ndns:\n') >= 0 ? 'enabled' : 'missing');
    try {
      this.writeTextFileSync(this.context.filesDir + '/lian-active-config.json',
        JSON.stringify({ path: path, homeDir: homeDir }));
    } catch (_err) {
      throw new Error('VPN 运行配置标记写入失败');
    }
    const timestamp = new Date().toISOString();
    const config: GeneratedConfig = {
      path: path,
      controllerUrl: 'http://' + LOCAL_CONTROLLER,
      mixedPort: LOCAL_MIXED_PORT,
      timestamp: timestamp
    };
    this.persistConfig(config);
    return config;
  }

  loadGeneratedConfig(): GeneratedConfig | null {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      const raw = store.getSync(KEY_GENERATED, '') as string;
      if (raw.length === 0) {
        return null;
      }
      const config = JSON.parse(raw) as GeneratedConfig;
      if (typeof config.path !== 'string' || config.path.length === 0) {
        return null;
      }
      return config;
    } catch (_err) {
      return null;
    }
  }

  private persistConfig(config: GeneratedConfig): void {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      store.putSync(KEY_GENERATED, JSON.stringify(config));
      store.flush();
    } catch (_err) {
      throw new Error('生成配置元数据保存失败');
    }
  }

  /**
   * 读取当前生成配置里的规则列表（即 mihomo 实际加载的规则，真实数据）。
   */
  readGeneratedRules(): RuleItem[] {
    const text = this.readGeneratedText();
    const out: RuleItem[] = [];
    if (text.length === 0) {
      return out;
    }
    const lines: string[] = text.split('\n');
    let inRules: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.startsWith('rules:')) {
        inRules = true;
        continue;
      }
      if (!inRules) {
        continue;
      }
      const trimmed: string = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      if (!trimmed.startsWith('- ')) {
        break;
      }
      const parts: string[] = trimmed.substring(2).trim().split(',');
      if (parts.length === 2) {
        // MATCH,自动选择
        out.push({ type: parts[0].trim(), payload: '', proxy: parts[1].trim() });
      } else if (parts.length >= 3) {
        let payload: string = parts[1].trim();
        if (parts.length > 3) {
          payload = payload + ' (' + parts.slice(3).join(',').trim() + ')';
        }
        out.push({ type: parts[0].trim(), payload: payload, proxy: parts[2].trim() });
      }
    }
    return out;
  }

  /**
   * 读取当前生成配置里的 DNS 设置（真实上游服务器与增强模式）。
   */
  readGeneratedDns(): DnsServer[] {
    const text = this.readGeneratedText();
    const out: DnsServer[] = [];
    if (text.length === 0) {
      return out;
    }
    const lines: string[] = text.split('\n');
    let inDns: boolean = false;
    let section: string = '';
    let index: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.startsWith('dns:')) {
        inDns = true;
        continue;
      }
      if (!inDns) {
        continue;
      }
      if (line.length > 0 && !line.startsWith(' ')) {
        break;
      }
      const trimmed: string = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      if (trimmed === 'nameserver:' || trimmed === 'fallback:') {
        section = trimmed.substring(0, trimmed.length - 1);
        index = 0;
        continue;
      }
      if (trimmed.startsWith('- ') && section.length > 0) {
        index++;
        out.push({
          name: (section === 'nameserver' ? '主 DNS ' : '备用 DNS ') + index,
          address: trimmed.substring(2).trim(),
          latency: '-',
          kind: section
        });
      }
    }
    return out;
  }

  /** 生成配置里 DNS 的增强模式（真实生效值） */
  readGeneratedDnsMode(): string {
    const text = this.readGeneratedText();
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const trimmed: string = lines[i].trim();
      if (trimmed.startsWith('enhanced-mode:')) {
        return trimmed.substring('enhanced-mode:'.length).trim();
      }
    }
    return '';
  }

  /** 生成配置的真实摘要：大小 · 生成时间 · 规则条数 */
  generatedConfigSummary(): string {
    try {
      const path = this.context.filesDir + CONFIG_DIR + CONFIG_FILE;
      const stat = fileIo.statSync(path);
      const sizeKb: string = (stat.size / 1024).toFixed(1);
      const mtimeMs: number = stat.mtime > 100000000000 ? stat.mtime : stat.mtime * 1000;
      const d = new Date(mtimeMs);
      const hh: string = d.getHours() < 10 ? '0' + d.getHours() : '' + d.getHours();
      const mm: string = d.getMinutes() < 10 ? '0' + d.getMinutes() : '' + d.getMinutes();
      const rules: number = this.readGeneratedRules().length;
      return sizeKb + ' KB · ' + hh + ':' + mm + ' · ' + rules + ' 条规则';
    } catch (_err) {
      return '尚未生成';
    }
  }

  private readGeneratedText(): string {
    try {
      return fileIo.readTextSync(this.context.filesDir + CONFIG_DIR + CONFIG_FILE);
    } catch (_err) {
      return '';
    }
  }

  /** 出站模式：规则 / 全局 / 直连 */
  private mihomoMode(proxyMode: string): string {
    if (proxyMode === '全局') {
      return 'global';
    }
    if (proxyMode === '直连') {
      return 'direct';
    }
    return 'rule';
  }

  /**
   * 取订阅自带规则里的 MATCH 兜底出口名 —— 这是订阅中一定存在的策略组名。
   * 用于两处：注入 AI 规则的目标，以及给加密 DNS 加 `#组名` 出口标记。
   * 取不到时返回空字符串，调用方据此放弃注入/标记（宁可维持原状也不能引用
   * 不存在的代理名，那会让 mihomo 直接 fatal 起不来）。
   */
  private resolveDefaultOutbound(rulesSection: string): string {
    const lines: string[] = rulesSection.split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      const trimmed: string = lines[i].trim();
      if (trimmed.startsWith('- MATCH,')) {
        return trimmed.substring('- MATCH,'.length).trim();
      }
    }
    return '';
  }

  /**
   * 在订阅自带规则的最前面注入 AI 代理规则。
   *
   * 目标策略组取自订阅自己的 MATCH 兜底规则 —— 只有这样才保证该组一定存在。
   * 绝不能写死 '自动选择'：Clash YAML 订阅的策略组名各不相同，引用到不存在的
   * 组会让 mihomo 直接启动失败，那比连不上更糟。
   * 找不到 MATCH 兜底时原样返回，宁可不注入也不冒险。
   */
  /**
   * 注入本应用强制要求的规则。
   *
   * 顺序很重要：注入内容放在订阅自带规则的最前面，因此**优先于订阅的一切规则**。
   *
   *  - 第 1 段「局域网直连」：私有 IP 永远不该出国。订阅规则里常见的
   *    `MATCH,节点` 兜底会把「应用自己解析出的私有地址」也交给代理；
   *    更危险的是 TUN 网关自己（10.6.0.2，同时是系统 DNS），一旦被代理就形成
   *    「用代理解析代理」的死循环 —— DNS 全挂。
   *  - 第 2 段「AI 代理」：必须在订阅的 GEOIP,CN 之前，否则被污染的解析结果
   *    会让 GEOIP,CN 先命中直连，表现为 ChatGPT 连不上。
   */
  private injectAiRules(section: string, geoReady: boolean = true): string {
    const target: string = this.resolveDefaultOutbound(section);
    const lines: string[] = section.split('\n');
    const injected: string[] = [];

    // ---- 第 1 段：局域网 / 特殊网段直连（无条件注入）----
    // GEOIP,lan 在 NewGEOIP 里 country=="lan" 分支提前 return，**不触发**
    // geodata.InitGeoIP()（rules/common/geoip.go:213），无需 geo 数据即可用；
    // IP-CIDR 同理。所以这一段任何情况下都能安全注入。
    // 但 GEOSITE / GEOIP,<国码> 都会调 InitGeoSite/InitGeoIP，缺数据会让规则
    // 创建失败 → 核心起不来，故这两条只在 geoReady 时注入。
    if (geoReady) {
      injected.push('  - GEOSITE,private,DIRECT');
      injected.push('  - GEOIP,private,DIRECT');
    }
    injected.push('  - GEOIP,lan,DIRECT');
    const directCidrs: string[] = [
      '192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12', '127.0.0.0/8',
      '169.254.0.0/16', '100.64.0.0/10', '198.18.0.0/15', '224.0.0.0/4',
      '240.0.0.0/4', '255.255.255.255/32'
    ];
    for (let i = 0; i < directCidrs.length; i++) {
      injected.push('  - IP-CIDR,' + directCidrs[i] + ',DIRECT,no-resolve');
    }

    // ---- 第 2 段：AI 代理（跟随用户手动选择的出口）----
    //
    // 历史行为：AI 流量被强制走「只含美国节点」的专用组，理由是 ChatGPT
    // 对部分地区不可用（曾实测选中卡塔尔出口导致 403）。
    //
    // 现已按用户要求取消该限制：AI 类域名不再单独指定出口，而是与其它
    // 流量一样跟随「手动选择」组 —— 用户选了哪个节点，ChatGPT 就走哪个。
    // 这样避免「手动选了日本/香港，ChatGPT 却偷偷走美国」的不一致。
    // 若所选地区恰好不被 OpenAI 支持，需要在界面手动切到可用地区。
    if (target.length > 0) {
      // 出口用订阅自带的兜底组（target）——本方法服务于「订阅自带配置」路径，
      // 该路径下的策略组全部来自订阅本身，本应用**不会**创建 MANUAL_GROUP。
      // 若在此处引用 MANUAL_GROUP，规则会指向一个不存在的组，
      // 导致 mihomo 直接启动失败（errMissProxy）。
      const aiTarget: string = target;
      // 与 buildConvertedYaml 中的 AI 段保持一致；必须排在 GEOIP,CN 之前。
      if (section.indexOf('GEOSITE') >= 0) {
        injected.push('  - GEOSITE,openai,' + aiTarget);
        injected.push('  - GEOSITE,category-ai-chat-!cn,' + aiTarget);
        injected.push('  - GEOSITE,category-ai-!cn,' + aiTarget);
      }
      const aiSuffixes: string[] = [
        'openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com', 'sora.com'
      ];
      for (let i = 0; i < aiSuffixes.length; i++) {
        injected.push('  - DOMAIN-SUFFIX,' + aiSuffixes[i] + ',' + aiTarget);
      }
    }

    const out: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      out.push(lines[i]);
      if (i === 0) {
        for (let j = 0; j < injected.length; j++) {
          out.push(injected[j]);
        }
      }
    }
    return out.join('\n');
  }

  private buildPreservedYaml(raw: string, mode: string = 'rule', geoReady: boolean = true): string {
    const sections = this.extractSections(raw);
    if (sections['proxies:'] === undefined && sections['proxy-providers:'] === undefined) {
      throw new Error('订阅中没有 proxies 或 proxy-providers');
    }
    const lines: string[] = [];
    this.appendHeader(lines, mode, '');
    // DNS 出口标记取订阅自带的 MATCH 兜底组名，保证该名字一定存在。
    const preservedRules: string = sections['rules:'] ?? '';
    this.appendDns(lines, this.resolveDefaultOutbound(preservedRules), geoReady);
    const order: string[] = [
      'proxies:', 'proxy-providers:', 'proxy-groups:', 'rules:', 'rule-providers:'
    ];
    let rulesWritten: boolean = false;
    for (let i = 0; i < order.length; i++) {
      const key: string = order[i];
      const section = sections[key];
      if (section !== undefined && section.length > 0) {
        lines.push('');
        if (key === 'rules:') {
          lines.push(this.injectAiRules(section, geoReady));
          rulesWritten = true;
        } else if (key === 'proxies:') {
          // 订阅自带 proxies 逐条补 udp: true（见 shareYaml 的说明）
          lines.push(this.injectUdpIntoProxies(section));
        } else if (key === 'proxy-providers:') {
          // provider 形式：用官方 override 打开 UDP，不改订阅内容本身
          lines.push(this.injectUdpIntoProviders(section));
        } else if (key === 'proxy-groups:') {
          // 不再注入 AI 专用组：AI 流量跟随用户手动选择的出口（见 injectAiRules）。
          lines.push(section);
        } else {
          lines.push(section);
        }
      }
    }
    if (!rulesWritten) {
      // 订阅没有 rules 段：mihomo 在无规则命中时兜底走 proxies["DIRECT"]，
      // 会让「该走代理的全部直连」。这里补一个最小可用规则集：
      // 局域网直连 + MATCH 指向订阅自带的第一个策略组。
      const fallbackTarget: string = this.firstGroupName(sections['proxy-groups:'] ?? '');
      if (fallbackTarget.length > 0) {
        lines.push('');
        lines.push(this.injectAiRules('rules:', geoReady) + '\n  - MATCH,' + fallbackTarget);
        hilog.warn(CFG_DOMAIN, CFG_TAG,
          'subscription has no rules section; synthesized LAN-direct + MATCH rules');
      }
    }
    return lines.join('\n') + '\n';
  }




  /**
   * 本次生成使用的延迟测试地址（来自设置页，空值已归一化为默认值）。
   * 三处 url-test 组统一使用它，避免出现「设置页改了但分组仍用旧地址」。
   */
  private testUrlForGroups: string = DEFAULT_TEST_URL;

  /**
   * 校验测试地址可用性。
   *
   * 只接受 http/https 的绝对 URL。这层校验是必要的：该值会被直接写进
   * mihomo 配置的 `url:` 字段，非法值会让整组测速失败（而 url-test 组
   * 内无可用节点时，出口选择会退化成列表首个节点，表现为「选哪个都不快」）。
   */
  private isValidTestUrl(url: string): boolean {
    if (url.length < 8 || url.length > 512) {
      return false;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return false;
    }
    // 必须含主机名，且不含空白字符（YAML 写入后会被截断）
    const rest: string = url.substring(url.indexOf('://') + 3);
    if (rest.length === 0 || rest.indexOf('/') === 0) {
      return false;
    }
    for (let i = 0; i < url.length; i++) {
      const c: string = url.charAt(i);
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        return false;
      }
    }
    return true;
  }

  /** 从 `proxy-groups:` 段取第一个组名（作为无 rules 时的 MATCH 兜底出口）。 */
  private firstGroupName(section: string): string {
    const lines: string[] = section.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const trimmed: string = lines[i].trim();
      if (!trimmed.startsWith('- name:')) {
        continue;
      }
      let value: string = trimmed.substring('- name:'.length).trim();
      if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith('\'') && value.endsWith('\'')))) {
        value = value.substring(1, value.length - 1);
      }
      if (value.length > 0) {
        return this.quoteYaml(value);
      }
    }
    return '';
  }

  /**
   * 给订阅自带的 `proxies:` 段每个节点补一行 `udp: true`。
   *
   * 只在节点已有的键之后插入，不重排、不改写原有字段；已显式写了 `udp:`
   * 的节点原样保留（尊重订阅作者的意图，也可能是刻意的 false）。
   * mihomo 的 decoder 会忽略协议不支持的冗余键，因此对 hysteria2/tuic 无害。
   *
   * 两种写法都要处理：
   *  - 块风格（绝大多数）：`- name: x` 换行后跟 `    type: ss` …
   *  - 流风格：`- {name: x, type: ss}` 或整段 `proxies: [{…}, {…}]`
   * 流风格不能靠「换行追加」，否则会生成非法 YAML，必须就地插进花括号里。
   */
  private injectUdpIntoProxies(section: string): string {
    // 第一步：流风格就地注入（`{ ... }` 内补 `, udp: true`）
    const staged: string = section.indexOf('{') >= 0
      ? this.injectUdpIntoFlowMappings(section)
      : section;

    // 第二步：块风格逐项补行；已被流风格处理过的项跳过
    const lines: string[] = staged.split('\n');
    const out: string[] = [];
    let itemIndent: string = '';
    let hasUdp: boolean = false;
    let inItem: boolean = false;
    let handledInline: boolean = false;

    const flush = (): void => {
      if (inItem && !hasUdp && !handledInline) {
        out.push(itemIndent + 'udp: true');
      }
      inItem = false;
      hasUdp = false;
      handledInline = false;
    };

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      // 一级列表项开头：`- name: ...` 或 `- {name: ...}`
      if (trimmed.startsWith('- ')) {
        flush();
        inItem = true;
        // 该节点的缩进 = 列表项缩进 + 2（子键与 name 对齐）
        let indentLen: number = 0;
        while (indentLen < line.length && line[indentLen] === ' ') {
          indentLen++;
        }
        itemIndent = ' '.repeat(indentLen + 2);
        if (trimmed.indexOf('{') >= 0) {
          handledInline = true;
        }
        out.push(line);
        continue;
      }
      if (inItem && trimmed.startsWith('udp:')) {
        hasUdp = true;
      }
      out.push(line);
    }
    flush();
    return out.join('\n');
  }

  /**
   * 对文本里所有 `{...}` 流式映射就地注入 `udp: true`。
   * 花括号配对时会跳过引号内的内容，避免 `{name: "a}b"}` 提前收尾。
   */
  private injectUdpIntoFlowMappings(section: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < section.length) {
      if (section[i] === '{') {
        const close: number = this.matchClosingBrace(section, i);
        if (close < 0) {
          out += section.substring(i);
          break;
        }
        out += this.udpIntoFlowMap(section.substring(i, close + 1));
        i = close + 1;
        continue;
      }
      out += section[i];
      i++;
    }
    return out;
  }

  /** 从 start 处的 `{` 找到配对的 `}` 下标；找不到返回 -1。 */
  private matchClosingBrace(text: string, start: number): number {
    let depth: number = 0;
    let quote: string = '';
    for (let i = start; i < text.length; i++) {
      const ch: string = text[i];
      if (quote.length > 0) {
        if (ch === quote && text[i - 1] !== '\\') {
          quote = '';
        }
        continue;
      }
      if (ch === '"' || ch === '\'') {
        quote = ch;
        continue;
      }
      if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
        if (depth === 0) {
          return i;
        }
      }
    }
    return -1;
  }

  /**
   * 单个流式映射 `{...}`：在收尾 `}` 前插入 `, udp: true`。
   * 已含 udp 键时原样返回。同时兼容 `{}`（空映射）与已有尾逗号。
   */
  private udpIntoFlowMap(mapping: string): string {
    const close: number = mapping.lastIndexOf('}');
    if (close < 0) {
      return mapping;
    }
    const body: string = mapping.substring(0, close);
    // 已有 udp 键（含引号形式）则不动
    if (/[{,\s]udp\s*:/.test(body) || /^\{?\s*udp\s*:/.test(body)) {
      return mapping;
    }
    const tail: string = mapping.substring(close);
    const trimmedBody: string = body.replace(/\s+$/, '');
    // 空映射 `{}` 直接写键；否则用逗号续接
    if (trimmedBody === '{' || trimmedBody === '') {
      return trimmedBody + ' udp: true' + tail;
    }
    const needsComma: boolean = !trimmedBody.endsWith(',');
    return trimmedBody + (needsComma ? ',' : '') + ' udp: true' + tail;
  }

  /**
   * 给 `proxy-providers:` 下的每个 provider 注入 `override: {udp: true}`。
   *
   * 说明：provider 的节点是运行时从远端拉取的，无法在生成期逐条改写，
   * 官方为此提供了 override（`adapter/provider/override.go` 中的
   * `overrideSchema.UDP`），会在解析 provider 内容时统一套用。
   * 已存在 override 的 provider 不重复注入，避免破坏订阅原有配置。
   *
   * 实现要点：必须**先原样输出该 provider 的所有原有行**，再在末尾追加
   * override —— 早期版本用「跳过到下一个 provider」的写法会丢掉 type/url
   * 等字段，生成出没有 type 的 provider，核心直接起不来（已由解析器实测复现）。
   */
  private injectUdpIntoProviders(section: string): string {
    const lines: string[] = section.split('\n');
    const out: string[] = [];
    let pendingOverride: boolean = false;

    const flushOverride = (): void => {
      if (pendingOverride) {
        out.push('    override:');
        out.push('      udp: true');
        pendingOverride = false;
      }
    };

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      // 新 provider 开头：`  name:`（2 空格缩进、以冒号结尾）
      if (/^ {2}[^\s].*:\s*$/.test(line)) {
        flushOverride();
        out.push(line);
        // 扫描该 provider 的缩进块，判断是否已有 override
        let hasOverride: boolean = false;
        for (let j = i + 1; j < lines.length; j++) {
          if (lines[j].length > 0 && !lines[j].startsWith('    ')) {
            break;
          }
          if (lines[j].trim().startsWith('override:')) {
            hasOverride = true;
            break;
          }
        }
        pendingOverride = !hasOverride;
        continue;
      }
      out.push(line);
    }
    flushOverride();
    return out.join('\n');
  }

  private buildConvertedYaml(nodes: ProxyNode[], selectedNodeName: string = '',
    mode: string = 'rule', geoReady: boolean = false): string {
    const orderedNodes: ProxyNode[] = [];
    for (let i = 0; i < nodes.length; i++) {
      if (selectedNodeName.length > 0 && nodes[i].name === selectedNodeName) {
        orderedNodes.push(nodes[i]);
      }
    }
    for (let i = 0; i < nodes.length; i++) {
      if (selectedNodeName.length === 0 || nodes[i].name !== selectedNodeName) {
        orderedNodes.push(nodes[i]);
      }
    }
    const lines: string[] = [];
    this.appendHeader(lines, mode, ' share-link converter');
    // 该路径下策略组由本方法自己生成，组名已知，可直接用作 DNS 出口标记。
    // DNS and AI traffic must use the same selector. If DNS keeps using the
    // automatic group after the user pins a node in MANUAL_GROUP, the DNS
    // answer/CDN region and the HTTPS/WebSocket exit can diverge, which is
    // especially unstable for ChatGPT.
    this.appendDns(lines, MANUAL_GROUP, geoReady);
    lines.push('proxies:');
    for (let i = 0; i < orderedNodes.length; i++) {
      lines.push(this.shareYaml(orderedNodes[i]));
    }
    lines.push('proxy-groups:');
    // url-test：mihomo 周期性对组内节点做真实 URL 测速，
    // 自动选用可用且最快的节点 —— 节点失效时自动切换，避免长时间挂死。
    lines.push('  - name: ' + AUTO_SELECT_GROUP);
    lines.push('    type: url-test');
    lines.push('    url: ' + this.testUrlForGroups);
    lines.push('    interval: 180');
    lines.push('    tolerance: 50');
    lines.push('    lazy: false');
    lines.push('    proxies:');
    for (let i = 0; i < orderedNodes.length; i++) {
      lines.push('      - ' + this.quoteYaml(orderedNodes[i].name));
    }
    // 手动选择组：默认指向自动测速组，用户指定节点后由 select 语义锁住。
    // 第一个成员即默认值，所以"不操作时行为不变"。
    lines.push('  - name: ' + MANUAL_GROUP);
    lines.push('    type: select');
    lines.push('    proxies:');
    lines.push('      - ' + this.quoteYaml(AUTO_SELECT_GROUP));
    for (let i = 0; i < orderedNodes.length; i++) {
      lines.push('      - ' + this.quoteYaml(orderedNodes[i].name));
    }
    // AI 流量跟随用户手动选择的出口，不再单独建「只含美国节点」的组。
    const aiTarget: string = MANUAL_GROUP;
    lines.push('rules:');
    // AI / ChatGPT 相关域名必须走代理。放在 GEOIP,CN 之前很关键：
    // GEOIP 规则基于「解析后的 IP」判断，一旦解析被污染成国内 IP，
    // 排在后面的代理兜底就再也没机会命中，表现为 ChatGPT 连不上。
    const aiSuffixes: string[] = [
      'openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com', 'sora.com'
    ];
    if (geoReady) {
      // 内置 geo 数据可用：按地理规则分流，覆盖完整（域名 + IP 双维度）
      lines.push('  - GEOSITE,cn,DIRECT');
      lines.push('  - GEOSITE,private,DIRECT');
      // AI 类站点（geosite 名称已核对存在于内置 geosite.dat）
      lines.push('  - GEOSITE,openai,' + aiTarget);
      lines.push('  - GEOSITE,category-ai-chat-!cn,' + aiTarget);
      lines.push('  - GEOSITE,category-ai-!cn,' + aiTarget);
      for (let i = 0; i < aiSuffixes.length; i++) {
        lines.push('  - DOMAIN-SUFFIX,' + aiSuffixes[i] + ',' + aiTarget);
      }
      lines.push('  - GEOIP,CN,DIRECT');
      lines.push('  - GEOIP,private,DIRECT');
      // 常见国内服务补充（geo 数据偶发未收录时兜底）
      lines.push('  - DOMAIN-SUFFIX,baidu.com,DIRECT');
      lines.push('  - DOMAIN-SUFFIX,qq.com,DIRECT');
      lines.push('  - DOMAIN-SUFFIX,taobao.com,DIRECT');
      lines.push('  - DOMAIN-SUFFIX,bilibili.com,DIRECT');
      lines.push('  - DOMAIN-SUFFIX,hdslb.com,DIRECT');
    } else {
      // 未内置 geo 数据时使用内置域名清单（此分支不能用 GEOSITE）
      for (let i = 0; i < aiSuffixes.length; i++) {
        lines.push('  - DOMAIN-SUFFIX,' + aiSuffixes[i] + ',' + AUTO_SELECT_GROUP);
      }
      // 清单已按「实测 GEOIP,CN 会漏判的中国 CDN 边缘 IP」补齐：
      // qq.com / wechat.com / zhihu.com / meituan.com / pinduoduo.com / mi.com
      // 的部分边缘节点在 geoip.metadb 里被登记为 hk/sg，纯 IP 场景下 GEOIP,CN
      // 命中不到，必须靠域名规则兜住。
      const directDomains: string[] = [
        'baidu.com', 'qq.com', 'tencent.com', 'taobao.com', 'tmall.com', 'aliyun.com',
        'aliyuncs.com', 'bilibili.com', 'hdslb.com', 'weibo.com', 'bytedance.com',
        'douyin.com', '163.com', '126.com', '10086.cn', 'chinamobile.com', 'xiaomi.com',
        'mi.com', 'huawei.com', 'jd.com', 'sohu.com', 'sina.com.cn', 'csdn.net',
        'zhihu.com', 'douban.com', 'meituan.com', 'dianping.com', 'pinduoduo.com',
        'kuaishou.com', 'iqiyi.com', 'youku.com', 'ximalaya.com', 'netease.com',
        'wechat.com', 'weixin.qq.com', 'gtimg.com', 'qpic.cn', 'qlogo.cn',
        'gov.cn', '12306.cn', 'icbc.com.cn', 'cmbchina.com', 'alipay.com',
        'cnblogs.com', 'bce.baidu.com', 'bdstatic.com', 'byteimg.com', 'zhipin.com'
      ];
      for (let i = 0; i < directDomains.length; i++) {
        lines.push('  - DOMAIN-SUFFIX,' + directDomains[i] + ',DIRECT');
      }
    }
    // 局域网 / 特殊网段兜底直连。放在所有代理规则之后、MATCH 之前：
    // 这些地址永远不应该出国，尤其是 TUN 自己的网关（10.6.0.2，同时是系统 DNS），
    // 一旦被交给代理就会形成「用代理解析代理」的死循环。
    //
    // GEOIP,lan 放在这里（而非上面的 geo 分支）：它在 NewGEOIP 里走
    // country=="lan" 提前 return，**不触发 geodata.InitGeoIP()**
    // （rules/common/geoip.go:213），因此无需 geo 数据即生效。
    // 其判定为 ip.IsPrivate() || IsUnspecified() || IsLoopback() ||
    // IsMulticast() || IsLinkLocalUnicast()，语义比 metadb 的 `private` 码更宽、
    // 也不依赖 mmdb 内容，所以在有/无 geo 数据两条路径下都注入。
    //
    // CGNAT(100.64/10)、基准测试段(198.18/15)、链路本地(169.254/16)、组播(224/4)
    // 与保留段(240/4) 都是容易漏掉的类别，故此处再显式兜一层。
    lines.push('  - GEOIP,lan,DIRECT');
    const directCidrs: string[] = [
      '192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12', '127.0.0.0/8',
      '169.254.0.0/16', '100.64.0.0/10', '198.18.0.0/15', '224.0.0.0/4',
      '240.0.0.0/4', '255.255.255.255/32'
    ];
    for (let i = 0; i < directCidrs.length; i++) {
      lines.push('  - IP-CIDR,' + directCidrs[i] + ',DIRECT,no-resolve');
    }
    // MATCH 指向手动选择组：它默认指向自动测速组（行为与之前一致），
    // 但用户手动指定节点后能真正锁住出口（url-test 组做不到这点）。
    lines.push('  - MATCH,' + MANUAL_GROUP);
    return lines.join('\n') + '\n';
  }

  /**
   * DNS 出口标记：让加密 DNS 的查询**经代理**发出。
   *
   * 为什么要这样：实测发现国内解析器（连 doh.pub 这类国内加密 DNS 也一样）
   * 在国内出口下仍会返回被污染的答案 —— chatgpt.com 曾被解析成
   * 185.60.218.50（Meta 网段）、android.chat.openai.com 解析成 192.133.77.59。
   * 只有把 DoH 查询本身送出国，才能拿到 Cloudflare 的真实 IP
   * （chatgpt.com → 104.18.32.47 / 172.64.155.209）。
   *
   * 约束（已用 mihomo 1.10.0 + 真实订阅节点实测）：
   *  - `#名字` 必须是**已存在的策略组或节点名**。mihomo 查不到该名字时会把它
   *    退化成网卡名（dialer.WithInterface），DNS 随即绑到不存在的网卡上全挂，
   *    因此只在确认组名真实存在时才加标记。
   *  - 规则里引用不存在的代理会让 mihomo 直接 fatal 启动失败，所以注入规则
   *    同样必须用订阅里真实存在的组名（见 injectAiRules）。
   */
  private dnsTag(groupName: string): string {
    return groupName.length > 0 ? '#' + groupName : '';
  }

  /**
   * DNS 段。
   * @param dnsProxyName 给加密 DNS 加 `#组名` 的出口标记；传空字符串则不加。
   * @param geoReady 内置 geo 数据是否就位；决定能否注入 `geosite:cn` policy。
   */
  private appendDns(lines: string[], dnsProxyName: string = '', geoReady: boolean = false): void {
    const tag: string = this.dnsTag(dnsProxyName);
    const overseas: string[] = [
      'https://1.1.1.1/dns-query' + tag,
      'https://dns.google/dns-query' + tag
    ];
    lines.push('dns:');
    lines.push('  enable: true');
    // VpnConfig.dnsAddresses can only advertise an IP address, so the
    // resolver always targets port 53. Keep mihomo on the standard DNS port
    // so queries stay inside the TUN instead of bypassing the core.
    lines.push('  listen: 0.0.0.0:53');
    // HarmonyOS ArkWeb currently does not reliably return traffic addressed
    // to mihomo's fake-ip pool through the VPN TUN. Real answers keep the
    // route decision in mihomo while avoiding that platform-specific loop.
    lines.push('  enhanced-mode: redir-host');
    lines.push('  nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 114.114.114.114');
    // 用纯 IP 的国内解析器给 DoH/DoT 域名自身做引导解析，
    // 否则“用 https://dns.google 解析 dns.google”会形成死循环。
    lines.push('  default-nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 114.114.114.114');
    // 实测（HarmonyOS 7 真机 / mihomo 1.10.0）：国内解析器会把
    // chatgpt.com / android.chat.openai.com / api.openai.com / ab.chatgpt.com
    // 污染成 Dropbox、Verizon、Facebook、Meta 等完全无关网段的 IP，而
    // auth.openai.com 却可能返回正常值 —— 表现为“ChatGPT 时好时坏、反复连不上”。
    // 命中污染 IP 后，分流规则（MATCH→节点）仍会把这条错连接交给节点，
    // TLS 对不上目标，所以问题不在规则而在解析。
    //
    // 修复：AI 与境外站点改走「经代理发出的境外加密 DNS」；命中 policy 时
    // mihomo 不会落入 main/fallback，因此这些域名能稳定拿到真实 IP。
    //
    // 另一个必须遵守的约束：每个 geosite 必须单独作为一个 key。
    // 写成 "geosite:a,geosite:b" 会被解析成 "geosite:geosite"，
    // 直接导致 load GeoSite data error → 核心启动失败。
    const aiPolicies: string[] = [
      'openai', 'category-ai-chat-!cn', 'category-ai-!cn',
      'google', 'geolocation-!cn'
    ];
    lines.push('  nameserver-policy:');
    // 国内域名同样要用 policy 钉到纯国内解析器上，这是「直连慢」的关键修复。
    //
    // 为什么必须走 policy 而不是留给 fallback-filter：
    // resolver.ipExchange 只在**答案集里每一个 IP 都不是 CN**时才提前返回：
    //
    //     shouldNotFallback := lo.EveryBy(ips, func(ip) bool {
    //         return !r.shouldIPFallback(ip)      // geoip 过滤器在此是取反语义
    //     })
    //     if shouldNotFallback { return }          // 快
    //     res = <-fallbackMsg                      // 否则等经代理的 fallback
    //
    // 而 geoip.metadb 会把一部分**中国 CDN 边缘 IP** 登记为 hk/sg
    // （实测 didiglobal.com / qq.com.cn / myqcloud.com / tencent-cloud.com
    // 的整个 A 记录集都被判为境外）。于是：
    //   - 国内解析器其实已经拿到正确答案（1ms 级）；
    //   - 但 lo.EveryBy 为 false，ipExchange 仍要等 fallback；
    //   - fallback 是带 `#组名` 的 DoH，必须**经代理节点出国**才能到 1.1.1.1；
    //   - 原本 1ms 的直连解析被拖到 fallback 超时（实测 3s）。
    // 这也解释了为什么症状集中在「原生应用直连」：它们自己解析 DNS 或
    // 复用连接，冷启动首次解析就撞上这个等待。
    //
    // 命中 policy 时 ipExchange 在**最开头**就 return，根本不进入 fallback
    // 分支，所以对 geosite:cn 一次性消除该等待。
    //
    // 约束（与上面 AI 段相同）：每个 geosite 必须独立成 key；且 geosite 会
    // 调用 InitGeoSite，缺 geo 数据会让规则创建失败 → 核心起不来，因此只在
    // geoReady 时注入。
    if (geoReady) {
      lines.push('    "geosite:cn":');
      lines.push('      - 223.5.5.5');
      lines.push('      - 114.114.114.114');
    }
    for (let i = 0; i < aiPolicies.length; i++) {
      lines.push('    "geosite:' + aiPolicies[i] + '":');
      for (let j = 0; j < overseas.length; j++) {
        lines.push('      - ' + overseas[j]);
      }
    }
    // 兜底：未被 policy 覆盖的域名，若国内解析器给出可疑结果则改用加密解析器；
    // 同样经代理发出，避免“国内出口查境外 DNS 仍被污染”。
    lines.push('  fallback:');
    for (let j = 0; j < overseas.length; j++) {
      lines.push('    - ' + overseas[j]);
    }
    lines.push('  fallback-filter:');
    lines.push('    geoip: true');
    lines.push('    geoip-code: CN');
    lines.push('    ipcidr:');
    lines.push('      - 240.0.0.0/4');
    // 节点服务器域名必须用国内 DNS 解析，否则“用代理解析代理地址”形成死循环。
    lines.push('  proxy-server-nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 114.114.114.114');
  }

  private ssPluginYaml(link: string): string {
    try {
      const qIdx = link.indexOf('?');
      if (qIdx < 0) {
        return '';
      }
      const frag = link.substring(qIdx + 1);
      const hashIdx = frag.indexOf('#');
      const query = hashIdx >= 0 ? frag.substring(0, hashIdx) : frag;
      const pluginRaw = this.queryParam(query, 'plugin');
      if (pluginRaw.length === 0) {
        return '';
      }
      const pluginParts = pluginRaw.split(';');
      if (pluginParts.length === 0 || pluginParts[0].indexOf('obfs') < 0) {
        return '';
      }
      let obfsMode = '';
      let obfsHost = '';
      for (let i = 1; i < pluginParts.length; i++) {
        const idx = pluginParts[i].indexOf('=');
        if (idx <= 0) {
          continue;
        }
        const key = pluginParts[i].substring(0, idx);
        const value = pluginParts[i].substring(idx + 1);
        if (key === 'obfs') {
          obfsMode = value;
        } else if (key === 'obfs-host') {
          obfsHost = value;
        }
      }
      let out = '\n    plugin: obfs';
      if (obfsMode.length > 0 || obfsHost.length > 0) {
        out += '\n    plugin-opts:';
        if (obfsMode.length > 0) {
          out += '\n      mode: ' + this.quoteYaml(obfsMode);
        }
        if (obfsHost.length > 0) {
          out += '\n      host: ' + this.quoteYaml(obfsHost);
        }
      }
      return out;
    } catch (_err) {
      return '';
    }
  }

  private queryParam(query: string, key: string): string {
    const parts = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const idx = parts[i].indexOf('=');
      if (idx > 0 && parts[i].substring(0, idx) === key) {
        return decodeURIComponent(parts[i].substring(idx + 1));
      }
    }
    return '';
  }

  /**
   * UDP 开关行。
   *
   * 背景（实测）：mihomo 的 UDP 支持由 `BaseOption.UDP` 决定，缺省 false；
   * 而 `tunnel.match()` 对 `metadata.NetWork == UDP && !adapter.SupportUDP()`
   * 的处理是 `continue`（跳到下一条规则），不是回退直连。因此当**所有**节点都
   * 不带 `udp: true` 时，规则链里每一条指向代理的规则都会被跳过，UDP 连接最终
   * 落到 `MATCH` 之后的兜底 `proxies["DIRECT"]`，表现为「所有 UDP 悄悄走直连」：
   * QUIC/HTTP-3、游戏、IM 语音等该走代理的没走，受屏蔽站点直接连不上。
   *
   * 对本身就没有 `udp` 字段的协议（hysteria2 / tuic 恒为 true），多写这一行是
   * 无副作用的冗余键（decoder 忽略未使用字段，已实测不报错）。
   */
  private udpLine(): string {
    return '\n    udp: true';
  }

  /**
   * 通用配置头：端口 / 出站模式 / ipv6 / sniffer / 控制器。
   *
   * `ipv6: false` 是**显式**声明。mihomo 的 `general.ipv6` 缺省为 true
   * （config.go:484），而 TUN 侧 `isIPv6Accepted: false` 且只有 IPv4 默认路由，
   * 两边不一致。DNS 层真正过滤 AAAA 的条件是 `dns.ipv6 && general.ipv6`
   * （executor.go:249），而 `dns.ipv6` 缺省为 false，所以当前 AAAA 已被过滤 ——
   * 但那是**巧合**而非本意：一旦将来显式打开 `dns.ipv6`，就会变成「返回 AAAA
   * 却无 IPv6 通路」，应用会卡在 IPv6 尝试上。显式写死 false 把这个巧合变成约定。
   *
   * sniffer 段：让「只有目标 IP、没有域名」的连接（应用自带 DNS、硬编码 IP、
   * 连接复用）能从 TLS SNI / HTTP Host / QUIC 里还原域名，从而命中
   * GEOSITE,cn → DIRECT。这是修复「该直连的没直连」的关键一环。
   * 数字型端口（如 3478、5004）与 mihomo 默认一致，避免误嗅探高风险端口。
   */
  private appendHeader(lines: string[], mode: string, comment: string): void {
    lines.push('# Generated by LIAN CONNECT 0.01' + comment);
    lines.push('mixed-port: ' + LOCAL_MIXED_PORT);
    lines.push('allow-lan: false');
    lines.push('mode: ' + mode);
    lines.push('external-controller: ' + LOCAL_CONTROLLER);
    // TUN 不接受 IPv6，核心侧也关掉，避免 AAAA 悬挂
    lines.push('ipv6: false');
    this.appendSniffer(lines);
  }

  /**
   * 嗅探器：把纯 IP 连接还原成域名，让域名类直连规则（GEOSITE,cn）能命中。
   *
   * 约束（已用真实 mihomo 解析器校验）：
   *  - 每个协议必须作为独立 key（HTTP / TLS / QUIC），与 geosite 同样的写法陷阱；
   *  - ports 必须用 mihomo 的区间语法（`80`、`8080-8880`），写成 `80,8080` 一类的
   *    逗号串在同一项里也能解析，但区间用 `-`；
   *  - `override-destination` 保持 false：只在连接尚无域名时补出域名，
   *    不覆盖 DNS 已解析出的真实目标，避免影响原有分流语义。
   */
  private appendSniffer(lines: string[]): void {
    lines.push('sniffer:');
    lines.push('  enable: true');
    lines.push('  override-destination: false');
    lines.push('  sniff:');
    lines.push('    HTTP:');
    lines.push('      ports: [80, 8080-8880]');
    lines.push('    TLS:');
    lines.push('      ports: [443, 8443]');
    lines.push('    QUIC:');
    lines.push('      ports: [443, 8443]');
  }

  private shareYaml(node: ProxyNode): string {
    const link = node.link === undefined ? '' : node.link;
    const name = this.quoteYaml(node.name);
    if (node.protocol === 'ss') {
      const parsed = this.parseSs(link);
      const plugin = this.ssPluginYaml(link);
      return '  - name: ' + name +
        '\n    type: ss' +
        '\n    server: ' + this.quoteYaml(parsed.server) +
        '\n    port: ' + parsed.port +
        '\n    cipher: ' + this.quoteYaml(parsed.uuid.length > 0 ? parsed.uuid : parsed.password.split(':')[0]) +
        '\n    password: ' + this.quoteYaml(parsed.uuid.length > 0 ? parsed.password : parsed.password.split(':').slice(1).join(':')) +
        this.udpLine() +
        plugin;
    }
    if (node.protocol === 'vmess') {
      const parsed = this.parseVmess(link);
      return '  - name: ' + name +
        '\n    type: vmess' +
        '\n    server: ' + this.quoteYaml(parsed.server) +
        '\n    port: ' + parsed.port +
        '\n    uuid: ' + this.quoteYaml(parsed.uuid) +
        '\n    alterId: 0' +
        '\n    cipher: auto' +
        '\n    tls: ' + (parsed.tls === 'tls' || parsed.tls === 'true' ? 'true' : 'false') +
        this.udpLine();
    }
    if (node.protocol === 'vless' || node.protocol === 'trojan') {
      const parsed = this.parseUri(node.protocol, link);
      const type = node.protocol === 'vless' ? 'vless' : 'trojan';
      const secretKey = node.protocol === 'vless' ? 'uuid' : 'password';
      // security=reality 时同样必须 tls: true —— REALITY 是 TLS 的扩展，
      // 只发 reality-opts 而不开 tls 会被 mihomo 当成明文连接。
      const isReality: boolean = parsed.tls === 'reality';
      const tlsOn: boolean = isReality || parsed.tls === 'tls' || parsed.tls === 'true';
      let out: string = '  - name: ' + name +
        '\n    type: ' + type +
        '\n    server: ' + this.quoteYaml(parsed.server) +
        '\n    port: ' + parsed.port +
        '\n    ' + secretKey + ': ' + this.quoteYaml(parsed.password) +
        '\n    network: ' + this.quoteYaml(parsed.network) +
        '\n    tls: ' + (tlsOn ? 'true' : 'false');
      // XTLS flow（如 xtls-rprx-vision）必须保留，否则部分服务端拒绝握手
      if (parsed.flow.length > 0) {
        out += '\n    flow: ' + this.quoteYaml(parsed.flow);
      }
      // TLS 指纹：REALITY 常要求与服务端一致（如 safari / chrome）
      if (parsed.fingerprint.length > 0) {
        out += '\n    client-fingerprint: ' + this.quoteYaml(parsed.fingerprint);
      }
      // SNI：REALITY 用它做伪装域名，必须显式下发
      if (parsed.sni.length > 0) {
        out += '\n    servername: ' + this.quoteYaml(parsed.sni);
      }
      if (parsed.insecure) {
        out += '\n    skip-cert-verify: true';
      }
      if (isReality && parsed.realityPublicKey.length > 0) {
        out += '\n    reality-opts:';
        out += '\n      public-key: ' + this.quoteYaml(parsed.realityPublicKey);
        if (parsed.realityShortId.length > 0) {
          out += '\n      short-id: ' + this.quoteYaml(parsed.realityShortId);
        }
      }
      return out + this.udpLine();
    }
    if (node.protocol === 'hysteria2') {
      const parsed = this.parseUri('hysteria2', link);
      return '  - name: ' + name +
        '\n    type: hysteria2' +
        '\n    server: ' + this.quoteYaml(parsed.server) +
        '\n    port: ' + parsed.port +
        '\n    password: ' + this.quoteYaml(parsed.password);
    }
    if (node.protocol === 'tuic') {
      const parsed = this.parseUri('tuic', link);
      return '  - name: ' + name +
        '\n    type: tuic' +
        '\n    server: ' + this.quoteYaml(parsed.server) +
        '\n    port: ' + parsed.port +
        '\n    uuid: ' + this.quoteYaml(parsed.uuid) +
        '\n    password: ' + this.quoteYaml(parsed.password) +
        '\n    congestion-control: bbr';
    }
    return '  - name: ' + name + '\n    type: ss' + this.udpLine();
  }

  private parseSs(link: string): ShareNode {
    let payload = link.substring('ss://'.length);
    const hashIndex = payload.indexOf('#');
    if (hashIndex >= 0) {
      payload = payload.substring(0, hashIndex);
    }
    let userInfo = '';
    let hostPort = '';
    const atIndex = payload.lastIndexOf('@');
    if (atIndex >= 0) {
      userInfo = payload.substring(0, atIndex);
      hostPort = payload.substring(atIndex + 1);
    } else {
      // 整体 base64 格式：ss://base64(method:password@host:port)
      const whole = this.tryDecodeBase64(payload);
      if (whole.length > 0) {
        const innerAt = whole.lastIndexOf('@');
        if (innerAt >= 0) {
          userInfo = whole.substring(0, innerAt);
          hostPort = whole.substring(innerAt + 1);
        } else {
          // base64 解码后仍无 @，可能是带路径参数，尽力取 host:port
          const slash = whole.lastIndexOf('/');
          hostPort = slash >= 0 ? whole.substring(slash + 1) : whole;
          userInfo = slash >= 0 ? whole.substring(0, slash) : '';
        }
      }
    }
    let decodedUser = userInfo;
    try {
      decodedUser = decodeURIComponent(decodedUser);
    } catch (_err) {
      // Keep the original authority when it is not percent-encoded.
    }
    if (decodedUser.indexOf(':') < 0) {
      decodedUser = this.tryDecodeBase64(decodedUser);
      if (decodedUser.length === 0) {
        let urlSafe = userInfo.replace(/-/g, '+').replace(/_/g, '/');
        while (urlSafe.length % 4 !== 0) {
          urlSafe += '=';
        }
        decodedUser = this.tryDecodeBase64(urlSafe);
      }
    }
    return this.buildShareNode(decodedUser, hostPort);
  }

  private parseVmess(link: string): ShareNode {
    const payload = link.substring('vmess://'.length);
    const decoded = this.tryDecodeBase64(payload);
    if (decoded.length > 0 && decoded.startsWith('{')) {
      try {
        const obj = JSON.parse(decoded) as Record<string, string>;
        const node = this.emptyShareNode();
        node.server = obj['add'] !== undefined ? obj['add'] : '';
        node.port = obj['port'] !== undefined ? obj['port'] : '443';
        node.uuid = obj['id'] !== undefined ? obj['id'] : '';
        node.network = obj['net'] !== undefined ? obj['net'] : 'tcp';
        node.tls = obj['tls'] !== undefined ? obj['tls'] : '';
        return node;
      } catch (_err) {
      }
    }
    let body = payload;
    const hashIndex = body.indexOf('#');
    if (hashIndex >= 0) {
      body = body.substring(0, hashIndex);
    }
    const atIndex = body.lastIndexOf('@');
    const uuid = atIndex >= 0 ? body.substring(0, atIndex) : '';
    const hostPort = atIndex >= 0 ? body.substring(atIndex + 1) : body;
    return this.buildShareNode(uuid, hostPort);
  }

  private parseUri(protocol: string, link: string): ShareNode {
    let body = link.substring(protocol.length + 3);
    const hashIndex = body.indexOf('#');
    if (hashIndex >= 0) {
      body = body.substring(0, hashIndex);
    }
    const queryIndex = body.indexOf('?');
    let query = '';
    if (queryIndex >= 0) {
      query = body.substring(queryIndex + 1);
      body = body.substring(0, queryIndex);
    }
    const atIndex = body.lastIndexOf('@');
    const secret = atIndex >= 0 ? body.substring(0, atIndex) : '';
    const hostPort = atIndex >= 0 ? body.substring(atIndex + 1) : body;
    const node = this.buildShareNode(secret, hostPort);
    node.network = this.queryValue(query, 'type');
    if (node.network.length === 0) {
      node.network = 'tcp';
    }
    node.tls = this.queryValue(query, 'security');
    // REALITY / TLS 细节：这些参数必须原样带给 mihomo，缺失会导致握手失败。
    node.sni = this.queryValue(query, 'sni');
    node.flow = this.queryValue(query, 'flow');
    node.fingerprint = this.queryValue(query, 'fp');
    node.realityPublicKey = this.queryValue(query, 'pbk');
    node.realityShortId = this.queryValue(query, 'sid');
    const insecure: string = this.queryValue(query, 'insecure');
    node.insecure = insecure === '1' || insecure === 'true';
    return node;
  }

  private buildShareNode(userInfo: string, hostPort: string): ShareNode {
    const node = this.emptyShareNode();
    const atIndex = hostPort.lastIndexOf('@');
    const hostPart = atIndex >= 0 ? hostPort.substring(atIndex + 1) : hostPort;
    const parts = hostPart.split(':');
    if (parts.length > 0) {
      node.server = parts[0];
    }
    if (parts.length > 1) {
      let portRaw = parts[parts.length - 1];
      // 去掉 ?query 参数（如 ?plugin=...）与 / path
      const qIdx = portRaw.indexOf('?');
      if (qIdx >= 0) {
        portRaw = portRaw.substring(0, qIdx);
      }
      const sIdx = portRaw.indexOf('/');
      if (sIdx >= 0) {
        portRaw = portRaw.substring(0, sIdx);
      }
      node.port = portRaw;
    }
    if (node.port.length === 0) {
      node.port = '443';
    }
    const secretParts = userInfo.split(':');
    if (secretParts.length === 1) {
      node.password = userInfo;
      node.uuid = userInfo;
    } else if (secretParts.length >= 2) {
      node.uuid = secretParts[0];
      node.password = secretParts.slice(1).join(':');
    }
    return node;
  }

  private emptyShareNode(): ShareNode {
    return {
      server: '',
      port: '443',
      password: '',
      uuid: '',
      network: 'tcp',
      tls: '',
      sni: '',
      flow: '',
      fingerprint: '',
      realityPublicKey: '',
      realityShortId: '',
      insecure: false
    };
  }

  /**
   * 从 query 串里取参数值。
   *
   * 用 indexOf('=') 只切第一个等号，而不是 split('=') 后要求长度恰为 2：
   * REALITY 的 pbk / sid 常是 base64，末尾可能带 '=' 填充，
   * 用 split 会因为得到 3 段而整条丢弃 → 参数静默丢失 → 握手失败。
   */
  private queryValue(query: string, key: string): string {
    const parts: string[] = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const pair: string = parts[i];
      const eq: number = pair.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      if (pair.substring(0, eq) !== key) {
        continue;
      }
      const rawValue: string = pair.substring(eq + 1);
      // 链接里参数通常已按 URL 编码，这里尽力还原（%3D → '='）。
      try {
        return decodeURIComponent(rawValue);
      } catch (_err) {
        return rawValue;
      }
    }
    return '';
  }

  private tryDecodeBase64(content: string): string {
    try {
      let normalized = content;
      while (normalized.length % 4 !== 0) {
        normalized += '=';
      }
      const decoded = new util.Base64Helper().decodeSync(normalized);
      return buffer.from(decoded).toString('utf8');
    } catch (_err) {
      return '';
    }
  }

  private extractSections(raw: string): Record<string, string> {
    const lines = raw.split('\n');
    const sections: Record<string, string> = {};
    let currentKey = '';
    let currentLines: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.length === 0 || (line.length > 0 && line[0] === ' ')) {
        if (currentKey.length > 0) {
          currentLines.push(line);
        }
      } else {
        if (currentKey.length > 0) {
          sections[currentKey] = currentLines.join('\n');
        }
        currentKey = '';
        currentLines = [];
        for (let j = 0; j < SECTION_KEYS.length; j++) {
          if (line.startsWith(SECTION_KEYS[j])) {
            currentKey = SECTION_KEYS[j];
            currentLines.push(line);
            break;
          }
        }
      }
    }
    if (currentKey.length > 0) {
      sections[currentKey] = currentLines.join('\n');
    }
    return sections;
  }

  private quoteYaml(value: string): string {
    if (value.length === 0) {
      return '""';
    }
    let needsQuote = false;
    for (let i = 0; i < value.length; i++) {
      const ch = value[i];
      if (ch === ' ' || ch === '#' || ch === ':' || ch === '"' || ch === '\'' ||
        ch === '{' || ch === '}' || ch === '[' || ch === ']' || ch === ',' ||
        ch === '&' || ch === '*' || ch === '?' || ch === '|' || ch === '-' ||
        ch === '<' || ch === '>' || ch === '=' || ch === '!' || ch === '%' ||
        ch === '@' || ch === '\\') {
        needsQuote = true;
        break;
      }
    }
    if (!needsQuote) {
      return value;
    }
    let escaped = '';
    for (let i = 0; i < value.length; i++) {
      const ch = value[i];
      if (ch === '"') {
        escaped = escaped + '\\"';
      } else if (ch === '\\') {
        escaped = escaped + '\\\\';
      } else {
        escaped = escaped + ch;
      }
    }
    return '"' + escaped + '"';
  }

  private writeConfig(content: string): string {
    const dir = this.context.filesDir + CONFIG_DIR;
    this.ensureDir(dir);
    const path = dir + CONFIG_FILE;
    let fd = -1;
    try {
      const f = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fd = f.fd;
      fileIo.writeSync(fd, content);
    } catch (_err) {
      throw new Error('生成配置写入失败');
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (_err) {
        }
      }
    }
    return path;
  }

  private writeTextFileSync(path: string, content: string): void {
    let fd = -1;
    try {
      const f = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fd = f.fd;
      fileIo.writeSync(fd, content);
    } catch (_err) {
      throw new Error('文本文件写入失败');
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (_err) {
        }
      }
    }
  }

  private ensureDir(dir: string): void {
    try {
      fileIo.mkdirSync(dir, true);
      return;
    } catch (_err) {
      try {
        fileIo.accessSync(dir);
        return;
      } catch (_inner) {
        throw new Error('运行目录创建失败');
      }
    }
  }
}
