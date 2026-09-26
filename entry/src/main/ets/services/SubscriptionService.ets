import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import fileIo from '@ohos.file.fs';
import { http } from '@kit.NetworkKit';
import { buffer, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImportResult, ProxyNode, SubscriptionProfile } from '../models/ArkModels';

const DOMAIN = 0x2023;
const TAG = 'SubSvc';

const STORE_NAME = 'lian_subscriptions';
const KEY_PROFILES = 'subscription.profiles';
const KEY_ACTIVE_ID = 'subscription.activeId';
const SUB_DIR = '/subscriptions';
const UA = 'lian-connect/0.01';
const ACCEPT = 'application/x-yaml, text/yaml, text/plain';

export class SubscriptionService {
  private store: preferences.Preferences;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
  }

  loadProfiles(): SubscriptionProfile[] {
    let raw = '[]';
    let activeId = '';
    try {
      raw = this.store.getSync(KEY_PROFILES, '[]') as string;
      activeId = this.store.getSync(KEY_ACTIVE_ID, '') as string;
    } catch (_err) {
      return [];
    }
    let profiles: SubscriptionProfile[] = [];
    try {
      const parsed = JSON.parse(raw) as Object;
      if (Array.isArray(parsed)) {
        profiles = parsed as SubscriptionProfile[];
      }
    } catch (_err) {
      profiles = [];
    }
    profiles = profiles.filter((profile) => this.isValidProfile(profile));
    for (let i = 0; i < profiles.length; i++) {
      profiles[i].active = profiles[i].id === activeId;
    }
    return profiles;
  }

  getActive(): SubscriptionProfile | null {
    const profiles = this.loadProfiles();
    for (let i = 0; i < profiles.length; i++) {
      if (profiles[i].active) {
        return profiles[i];
      }
    }
    if (profiles.length > 0) {
      profiles[0].active = true;
      this.saveProfiles(profiles);
      return profiles[0];
    }
    return null;
  }

  async addSubscription(url: string, name: string): Promise<SubscriptionProfile> {
    const validUrl = this.validateUrl(url);
    const content = await this.fetchSubscription(validUrl);
    const result = this.analyzeContent(content);
    if (!result.ok) {
      throw new Error(result.message);
    }
    return this.persistProfile(name.length > 0 ? name : '我的订阅', validUrl, result);
  }

  addPastedContent(name: string, content: string): SubscriptionProfile {
    const result = this.analyzeContent(content);
    if (!result.ok) {
      throw new Error(result.message);
    }
    return this.persistProfile(name.length > 0 ? name : '剪贴板配置', 'pasted://local', result);
  }

  /**
   * 重新下载指定订阅并原地更新（保留 id 与激活状态，不产生重复订阅）。
   */
  async refreshSubscription(id: string): Promise<SubscriptionProfile> {
    const profiles = this.loadProfiles();
    let target: SubscriptionProfile | undefined = undefined;
    for (let i = 0; i < profiles.length; i++) {
      if (profiles[i].id === id) {
        target = profiles[i];
        break;
      }
    }
    if (target === undefined) {
      throw new Error('订阅不存在');
    }
    if (target.sourceUrl.indexOf('pasted://') === 0) {
      throw new Error('本地粘贴的配置无法刷新，请重新导入');
    }
    const validUrl = this.validateUrl(target.sourceUrl);
    const content = await this.fetchSubscription(validUrl);
    const result = this.analyzeContent(content);
    if (!result.ok) {
      throw new Error(result.message);
    }
    this.writeContent(id, result.content);
    const updated: SubscriptionProfile = {
      id: target.id,
      name: target.name,
      sourceUrl: target.sourceUrl,
      detectedFormat: result.format,
      nodeCount: result.nodeCount,
      updatedAt: new Date().toISOString(),
      active: target.active,
      content: ''
    };
    const next: SubscriptionProfile[] = [];
    for (let i = 0; i < profiles.length; i++) {
      next.push(profiles[i].id === id ? updated : profiles[i]);
    }
    this.saveProfiles(next);
    return updated;
  }

  selectSubscription(id: string): void {
    const profiles = this.loadProfiles();
    let found = false;
    for (let i = 0; i < profiles.length; i++) {
      profiles[i].active = profiles[i].id === id;
      if (profiles[i].active) {
        found = true;
      }
    }
    if (!found) {
      throw new Error('Subscription not found');
    }
    this.saveProfiles(profiles);
  }

  deleteSubscription(id: string): void {
    let profiles = this.loadProfiles();
    profiles = profiles.filter((profile) => profile.id !== id);
    if (profiles.length > 0) {
      profiles[0].active = true;
    }
    this.deleteContent(id);
    this.saveProfiles(profiles);
  }

  loadContent(id: string): string {
    const path = this.contentPath(id);
    try {
      return fileIo.readTextSync(path);
    } catch (_err) {
      return '';
    }
  }

  analyzeContent(content: string): ImportResult {
    const format = this.detectFormat(content);
    if (format === 'unsupported') {
      return {
        ok: false,
        message: '不支持的配置格式：请使用 Clash/Mihomo YAML、Base64 订阅或分享链接',
        format: format,
        nodeCount: 0,
        nodes: [],
        content: content
      };
    }
    const nodes = this.parseNodes(content, format);
    if (nodes.length === 0) {
      return {
        ok: false,
        message: '配置中未解析到可用节点',
        format: format,
        nodeCount: 0,
        nodes: [],
        content: content
      };
    }
    return {
      ok: true,
      message: this.formatLabel(format),
      format: format,
      nodeCount: nodes.length,
      nodes: nodes,
      content: content
    };
  }

  private persistProfile(name: string, sourceUrl: string, result: ImportResult): SubscriptionProfile {
    const id = this.newId();
    const profile: SubscriptionProfile = {
      id: id,
      name: name,
      sourceUrl: sourceUrl,
      detectedFormat: result.format,
      nodeCount: result.nodeCount,
      updatedAt: new Date().toISOString(),
      active: true,
      content: ''
    };
    this.writeContent(id, result.content);
    let profiles = this.loadProfiles();
    for (let i = 0; i < profiles.length; i++) {
      profiles[i].active = false;
    }
    profiles.push(profile);
    this.saveProfiles(profiles);
    return profile;
  }

  private validateUrl(url: string): string {
    const trimmed = url.trim();
    if (trimmed.length === 0) {
      throw new Error('订阅链接不能为空');
    }
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      throw new Error('订阅链接必须以 http:// 或 https:// 开头');
    }
    return trimmed;
  }

  private async fetchSubscription(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const response = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 30000,
        connectTimeout: 10000,
        header: {
          'User-Agent': UA,
          'Accept': ACCEPT
        }
      });
      const status = response.responseCode;
      if (status < 200 || status >= 300) {
        throw new Error('HTTP ' + status);
      }
      return response.result as string;
    } catch (err) {
      if (err instanceof Error && err.message.startsWith('HTTP ')) {
        throw err;
      }
      throw new Error('订阅下载失败，请检查网络和链接');
    } finally {
      req.destroy();
    }
  }

  private detectFormat(content: string): string {
    const trimmed = content.trim();
    if (trimmed.length === 0) {
      return 'unsupported';
    }
    if (trimmed.startsWith('proxies:') || trimmed.startsWith('proxy-groups:') ||
      trimmed.startsWith('rules:') || trimmed.startsWith('mixed-port:') ||
      trimmed.startsWith('port:') || trimmed.startsWith('socks-port:')) {
      return 'clash-yaml';
    }
    if (this.hasShareLink(trimmed)) {
      return 'share-links';
    }
    const decoded = this.tryDecodeBase64(trimmed);
    if (decoded.length > 0 && this.hasShareLink(decoded)) {
      return 'base64-links';
    }
    return 'unsupported';
  }

  private hasShareLink(content: string): boolean {
    const schemes: string[] = ['ss://', 'vmess://', 'vless://', 'trojan://', 'hysteria2://', 'tuic://'];
    for (let i = 0; i < schemes.length; i++) {
      if (content.indexOf(schemes[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  private tryDecodeBase64(content: string): string {
    try {
      const decoded = new util.Base64Helper().decodeSync(content);
      return buffer.from(decoded).toString('utf8');
    } catch (_err) {
      return '';
    }
  }

  private parseNodes(content: string, format: string): ProxyNode[] {
    if (format === 'clash-yaml') {
      return this.parseYamlNodes(content);
    }
    let text = content;
    if (format === 'base64-links') {
      text = this.tryDecodeBase64(content);
    }
    return this.parseShareNodes(text);
  }

  private parseYamlNodes(content: string): ProxyNode[] {
    const lines = content.split('\n');
    const nodes: ProxyNode[] = [];
    let index = 0;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.startsWith('- name:')) {
        let rawName = line.substring(7).trim();
        if (rawName.length >= 2 &&
          ((rawName.startsWith('"') && rawName.endsWith('"')) ||
            (rawName.startsWith('\'') && rawName.endsWith('\'')))) {
          rawName = rawName.substring(1, rawName.length - 1);
        }
        const name = rawName.length > 0 ? rawName : '节点 ' + (index + 1);
        nodes.push({
          name: name,
          protocol: this.protocolFromYaml(lines, i),
          group: '导入节点',
          latency: -1,
          selected: index === 0
        });
        index++;
      }
    }
    return nodes;
  }

  private protocolFromYaml(lines: string[], start: number): string {
    const end = Math.min(start + 8, lines.length);
    for (let i = start + 1; i < end; i++) {
      const line = lines[i].trim();
      if (line.startsWith('type:')) {
        return line.substring(5).trim();
      }
    }
    return 'unknown';
  }

  private parseShareNodes(content: string): ProxyNode[] {
    const lines = content.split('\n');
    const nodes: ProxyNode[] = [];
    let index = 0;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!this.hasShareLink(line)) {
        continue;
      }
      const protocol = this.shareProtocol(line);
      const name = this.shareName(line, protocol, index);
      if (index === 0) {
        hilog.info(DOMAIN, TAG, 'sample link[0] protocol=%{public}s name=%{public}s', protocol, name);
      }
      nodes.push({
        name: name,
        protocol: protocol,
        group: '分享链接',
        latency: -1,
        selected: index === 0,
        link: line
      });
      index++;
    }
    return nodes;
  }

  private shareProtocol(link: string): string {
    const schemes: string[] = ['ss://', 'vmess://', 'vless://', 'trojan://', 'hysteria2://', 'tuic://'];
    for (let i = 0; i < schemes.length; i++) {
      if (link.startsWith(schemes[i])) {
        return schemes[i].substring(0, schemes[i].length - 3);
      }
    }
    return 'unknown';
  }

  private shareName(link: string, protocol: string, index: number): string {
    const hashIndex = link.lastIndexOf('#');
    if (hashIndex >= 0 && hashIndex < link.length - 1) {
      const raw = link.substring(hashIndex + 1);
      if (raw.length > 0 && raw.indexOf('://') < 0) {
        return this.tryDecodeName(raw);
      }
    }
    if (protocol === 'vmess') {
      const payload = link.substring('vmess://'.length);
      const decoded = this.tryDecodeBase64(payload);
      try {
        const obj = JSON.parse(decoded) as Record<string, string>;
        const ps = obj['ps'];
        if (ps !== undefined && ps.length > 0) {
          return this.tryDecodeName(ps);
        }
      } catch (_err) {
      }
    }
    return protocol.toUpperCase() + ' ' + (index + 1);
  }

  private tryDecodeName(name: string): string {
    try {
      const decoded = decodeURIComponent(name);
      return decoded.length > 0 ? decoded : name;
    } catch (_err) {
      return name;
    }
  }

  private formatLabel(format: string): string {
    if (format === 'clash-yaml') {
      return 'Clash / Mihomo YAML 已识别';
    }
    if (format === 'base64-links') {
      return 'Base64 分享订阅已识别';
    }
    if (format === 'share-links') {
      return '分享链接已识别';
    }
    return '不支持';
  }

  private saveProfiles(profiles: SubscriptionProfile[]): void {
    try {
      this.store.putSync(KEY_PROFILES, JSON.stringify(profiles));
      let activeId = '';
      for (let i = 0; i < profiles.length; i++) {
        if (profiles[i].active) {
          activeId = profiles[i].id;
        }
      }
      this.store.putSync(KEY_ACTIVE_ID, activeId);
      this.store.flush();
    } catch (_err) {
      throw new Error('订阅元数据保存失败');
    }
  }

  private isValidProfile(profile: SubscriptionProfile): boolean {
    if (profile === null || profile === undefined) {
      return false;
    }
    if (typeof profile.id !== 'string' || profile.id.length === 0) {
      return false;
    }
    if (typeof profile.name !== 'string' || typeof profile.detectedFormat !== 'string') {
      return false;
    }
    return true;
  }

  private contentPath(id: string): string {
    const dir = this.context.filesDir + SUB_DIR;
    this.ensureDir(dir, '订阅存储目录创建失败');
    return dir + '/' + id + '.conf';
  }

  private ensureDir(dir: string, message: string): void {
    try {
      fileIo.mkdirSync(dir, true);
      return;
    } catch (_err) {
      try {
        fileIo.accessSync(dir);
        return;
      } catch (_inner) {
        throw new Error(message);
      }
    }
  }

  private writeContent(id: string, content: string): void {
    const path = this.contentPath(id);
    let fd = -1;
    try {
      const f = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fd = f.fd;
      fileIo.writeSync(fd, content);
    } catch (_err) {
      throw new Error('订阅内容写入失败');
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (_err) {
        }
      }
    }
  }

  private deleteContent(id: string): void {
    try {
      fileIo.unlinkSync(this.contentPath(id));
    } catch (_err) {
    }
  }

  private newId(): string {
    return Date.now().toString(36) + Math.random().toString(36).substring(2, 8);
  }
}
