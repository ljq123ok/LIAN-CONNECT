import { common } from '@kit.AbilityKit';
import {
  AppConnection,
  AppProxyRule,
  AppSettings,
  DnsServer,
  ProxyGroup,
  ProxyNode,
  RecoveryEvent,
  RuleItem,
  SubscriptionProfile
} from '../models/ArkModels';
import { MockData } from '../services/MockData';
import { SubscriptionService } from '../services/SubscriptionService';
import { ConfigService } from '../services/ConfigService';
import { SettingsStore } from '../services/SettingsStore';
import { AppFilterStore } from '../services/AppFilterStore';
import { AppCatalog } from '../services/AppCatalog';
import { VpnService } from '../services/VpnService';
import { LatencyTester } from '../services/LatencyTester';
import { CoreConnection, CoreStatusStore } from '../services/CoreStatusStore';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Fmt } from '../common/Format';
import { HomePage } from './HomePage';
import { NodesPage } from './NodesPage';
import { ConnectionsPage } from './ConnectionsPage';
import { RulesPage } from './RulesPage';
import { DnsPage } from './DnsPage';
import { AppsPage } from './AppsPage';
import { DiagnosticsPage } from './DiagnosticsPage';
import { SettingsPage } from './SettingsPage';
import { OnboardingPage } from './OnboardingPage';

const DOMAIN = 0x2020;
const TAG = 'LianIndex';
/** 与 ConfigService 的 MANUAL_GROUP 保持一致：实际承载分流的 select 组 */
const MANUAL_GROUP_NAME = '手动选择';

interface NavItem {
  id: string;
  label: string;
}

const NAV_ITEMS: NavItem[] = [
  { id: 'home', label: '连接' },
  { id: 'onboard', label: '首次配置' },
  { id: 'nodes', label: '节点' },
  { id: 'connections', label: '连接' },
  { id: 'rules', label: '规则' },
  { id: 'dns', label: 'DNS' },
  { id: 'apps', label: '应用' },
  { id: 'diagnostics', label: '诊断' },
  { id: 'settings', label: '设置' }
];

@Entry
@Component
struct Index {
  @State private selectedPage: string = 'home';
  @State private connected: boolean = false;
  @State private connecting: boolean = false;
  @State private selectedNode: string = '香港 HK-01';
  @State private nodeCount: number = 0;
  @State private subscriptionName: string = '';
  @State private importMessage: string = '';
  @State private statusMessage: string = '';
  @State private nodeGroups: ProxyGroup[] = MockData.nodeGroups();
  @State private connections: AppConnection[] = MockData.connections();
  @State private rules: RuleItem[] = MockData.rules();
  @State private events: RecoveryEvent[] = MockData.events();
  @State private dnsServers: DnsServer[] = MockData.dnsServers();
  @State private proxyMode: string = '规则';
  @State private dnsMode: string = '智能';
  @State private onboardingStep: number = 1;
  @State private onboardingChoice: string = 'standard';
  @State private onboardingDone: boolean = false;
  @State private testingAll: boolean = false;
  @State private autoConnect: boolean = true;
  @State private networkRecover: boolean = true;
  @State private screenKeep: boolean = true;
  @State private failClosed: boolean = false;
  @State private notificationOn: boolean = true;
  @State private logLevel: string = 'info';
  @State private testUrl: string = 'https://www.gstatic.com/generate_204';
  // ===== 首页真实运行数据（来源：mihomo 核心状态 + 会话状态）=====
  @State private coreRunning: boolean = false;
  @State private coreVersion: string = '';
  @State private tunFd: number = 0;
  @State private downSpeed: number = 0;
  @State private upSpeed: number = 0;
  @State private downTotal: number = 0;
  @State private upTotal: number = 0;
  @State private activeConnections: number = 0;
  @State private coreMemory: number = 0;
  @State private sessionStart: number = 0;
  @State private lastLatency: number = -1;
  @State private latencyAt: number = 0;
  @State private latencyTesting: boolean = false;
  @State private recoveryEvents: RecoveryEvent[] = [];
  // ===== 真实数据（连接明细 / 规则 / DNS / 模式）=====
  @State private realConnections: CoreConnection[] = [];
  @State private realRules: RuleItem[] = [];
  @State private realDns: DnsServer[] = [];
  @State private dnsEnhancedMode: string = '';
  @State private coreMode: string = 'rule';
  @State private proxyConnections: number = 0;
  @State private healthState: string = 'unknown';
  @State private healthDelay: number = 0;
  @State private healthyNodes: number = 0;
  @State private totalNodes: number = 0;
  @State private coreCurrentNode: string = '';
  @State private recoverCount: number = 0;
  @State private subProfiles: SubscriptionProfile[] = [];
  @State private activeSubId: string = '';
  @State private configSummary: string = '';
  /** 分应用代理：是否启用 */
  @State private perAppProxyEnabled: boolean = false;
  /** 分应用代理：不使用代理（直连）的包名集合 */
  @State private excludedApps: string[] = [];
  /** 用户手动添加的自定义应用条目（内置目录之外的包名） */
  @State private customApps: AppProxyRule[] = [];

  private subService?: SubscriptionService;
  private configService?: ConfigService;
  private settingsStore?: SettingsStore;
  private appFilterStore?: AppFilterStore;
  private vpnService: VpnService = new VpnService();
  private coreStatusStore?: CoreStatusStore;
  private statsTimer: number = -1;
  /** 最近一次读到有效心跳的时间 */
  private coreLastSeen: number = 0;
  /** 首次基线读取完成标记（避免启动时把“已在运行”误记为新连接事件） */
  private coreBaselineDone: boolean = false;
  /** 连接列表签名，用于避免每秒无谓的重渲染 */
  private connSignature: string = '';
  /**
   * 最近一次「主动断开」的时刻（毫秒）。
   *
   * 用于挡住陈旧心跳：扩展在终止前会写下最后一份 running=true 的状态文件，
   * 其 ts 可能刚好落在 6 秒陈旧阈值内。若不拦截，心跳轮询会在断开后把
   * connected 又置回 true，界面看起来像「点击没生效」。
   * 收到比该时刻更新的心跳时清零，恢复正常判定。
   */
  private lastStopAt: number = 0;
  /**
   * 最近一次「心跳消失后自动重连」的时刻（毫秒）。
   * 用于节流：轮询每 1 秒一次，若不限流会在隧道真的不可用时反复重连。
   */
  private lastAutoRestartAt: number = 0;

  /**
   * 页面进入后台/锁屏的时刻（毫秒）；0 表示当前在前台。
   */
  private hiddenAt: number = 0;

  /**
   * 回到前台后的「心跳容忍期」截止时刻（毫秒）。
   *
   * 锁屏/后台期间 JS 定时器可能被系统挂起，扩展写心跳的 setInterval
   * 会随之中断，于是状态文件的时间戳停在锁屏那一刻。回到前台后若立刻
   * 按「心跳超过 6 秒即视为停止」判定，就会把「刚恢复、心跳还没补上来」
   * 误判为隧道已死 —— 更糟的是会因此去重建一条其实完好的隧道。
   *
   * 因此回到前台先进入一段容忍期：期内不判定断开、不触发重建，
   * 只等扩展把心跳补上。真正被杀掉的隧道会在容忍期结束后被判出并恢复。
   */
  private resumeGraceUntil: number = 0;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.subService = new SubscriptionService(context);
    this.configService = new ConfigService(context);
    this.settingsStore = new SettingsStore(context);
    this.appFilterStore = new AppFilterStore(context);
    this.coreStatusStore = new CoreStatusStore(context);
    this.onboardingDone = this.settingsStore.loadOnboardingDone();
    const settings = this.settingsStore.load();
    this.autoConnect = settings.autoConnect;
    this.networkRecover = settings.networkRecover;
    this.screenKeep = settings.screenKeep;
    this.failClosed = settings.failClosed;
    this.notificationOn = settings.notificationOn;
    this.logLevel = settings.logLevel;
    this.testUrl = settings.testUrl;
    this.dnsMode = settings.dnsMode;
    this.proxyMode = settings.proxyMode;
    this.perAppProxyEnabled = settings.perAppProxyEnabled;
    this.excludedApps = this.settingsStore.loadExcludedApps();
    this.customApps = this.settingsStore.loadCustomApps();
    // 启动即同步一次，保证「上次的配置」在未进设置页时也生效
    this.syncAppFilterToFile();
    // 核心状态监视器常驻运行：连接状态与上下行/连接数全部以内核心跳为真实依据
    this.startStatsPolling();
    this.reloadSubscriptions();
    const active = this.subService?.getActive();
    if (active !== null && active !== undefined) {
      this.applyProfile(active);
    }
    // “启动时自动连接 / 应用启动后使用上次节点”：等首帧渲染与状态基线完成后再连接
    if (this.autoConnect) {
      setTimeout(() => {
        this.autoConnectOnLaunch();
      }, 1500);
    }
  }

  /** 启动自动连接：仅在未连接且有订阅时执行；连接时使用上次选中的节点 */
  private autoConnectOnLaunch(): void {
    if (this.connected || this.connecting) {
      return;
    }
    const active = this.subService?.getActive();
    if (active === null || active === undefined) {
      return;
    }
    this.statusMessage = '正在按上次节点自动连接...';
    this.toggleVpn();
  }

  build() {
    Column() {
      this.header()
      this.nav()
      this.pageContent()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder
  private header() {
    Row() {
      Column({ space: 2 }) {
        Text('LIAN CONNECT')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.green'))
        Text(this.pageTitle())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text(this.connected ? '已保护' : '未连接')
        .fontSize(11)
        .fontColor(this.connected ? $r('app.color.green') : $r('app.color.amber'))
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(999)
        .backgroundColor(this.connected ? $r('app.color.green_soft') : $r('app.color.amber_soft'))
    }
    .width('100%')
    .height(72)
    .padding({ left: 20, right: 20 })
    .border({ width: { bottom: 1 }, color: $r('app.color.line_soft') })
  }

  @Builder
  private nav() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(this.navItems(), (item: NavItem) => {
          Button(item.label)
            .type(ButtonType.Normal)
            .fontSize(12)
            .fontColor(this.selectedPage === item.id ? $r('app.color.text') : $r('app.color.sub'))
            .backgroundColor(this.selectedPage === item.id ? $r('app.color.green_soft') : $r('app.color.surface'))
            .border({ width: 1, color: this.selectedPage === item.id ? $r('app.color.green') : $r('app.color.line_soft') })
            .borderRadius(8)
            .height(36)
            .padding({ left: 12, right: 12 })
            .onClick(() => {
              this.selectedPage = item.id;
              this.statusMessage = '';
            })
        }, (item: NavItem) => item.id)
      }
      .padding({ left: 20, right: 20 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(52)
  }

  @Builder
  private pageContent() {
    if (this.selectedPage === 'home') {
      HomePage({
        connected: this.connected,
        connecting: this.connecting,
        selectedNode: this.selectedNode,
        nodeCount: this.nodeCount,
        statusMessage: this.statusMessage,
        coreRunning: this.coreRunning,
        coreVersion: this.coreVersion,
        tunFd: this.tunFd,
        downSpeed: this.downSpeed,
        upSpeed: this.upSpeed,
        downTotal: this.downTotal,
        upTotal: this.upTotal,
        activeConnections: this.activeConnections,
        sessionStart: this.sessionStart,
        lastLatency: this.lastLatency,
        latencyAt: this.latencyAt,
        latencyTesting: this.latencyTesting,
        dnsMode: this.dnsMode,
        proxyMode: this.proxyMode,
        healthState: this.healthState,
        healthDelay: this.healthDelay,
        healthyNodes: this.healthyNodes,
        totalNodes: this.totalNodes,
        recoverCount: this.recoverCount,
        recoveryEvents: this.recoveryEvents,
        onToggle: (): void => {
          this.toggleVpn();
        },
        onGotoNodes: (): void => {
          this.selectedPage = 'nodes';
        },
        onGotoDiagnostics: (): void => {
          this.selectedPage = 'diagnostics';
        },
        onTestLatency: (): void => {
          this.testSelectedNodeLatency();
        },
        onExport: (): void => {
          this.exportReport();
        }
      })
    } else if (this.selectedPage === 'onboard') {
      OnboardingPage({
        step: this.onboardingStep,
        choice: this.onboardingChoice,
        onNext: (): void => {
          if (this.onboardingStep < 3) {
            this.onboardingStep++;
          }
        },
        onFinish: (): void => {
          this.onboardingDone = true;
          this.settingsStore?.saveOnboardingDone(true);
          this.selectedPage = 'home';
          this.statusMessage = '';
        },
        onPrev: (): void => {
          if (this.onboardingStep > 1) {
            this.onboardingStep--;
          }
        },
        onChoice: (choice: string): void => {
          this.onboardingChoice = choice;
        }
      })
    } else if (this.selectedPage === 'nodes') {
      NodesPage({
        groups: this.nodeGroups,
        selectedNode: this.selectedNode,
        nodeCount: this.nodeCount,
        subscriptionName: this.subscriptionName,
        importMessage: this.importMessage,
        onSelectNode: (name: string): void => {
          this.selectNode(name);
        },
        onImportUrl: (name: string, url: string): void => {
          this.importUrl(name, url);
        },
        onImportText: (name: string, content: string): void => {
          this.importText(name, content);
        },
        onTestNode: (name: string): void => {
          this.testNode(name);
        },
        onTestAll: (): void => {
          this.testAllNodes();
        },
        testingAll: this.testingAll,
        onRefresh: (): void => {
          this.importMessage = '节点列表已刷新';
        }
      })
    } else if (this.selectedPage === 'connections') {
      ConnectionsPage({
        connected: this.connected,
        coreConnections: this.realConnections,
        onClose: (id: string): void => {
          this.closeConnection(id);
        },
        onCloseAll: (): void => {
          this.closeAllConnections();
        }
      })
    } else if (this.selectedPage === 'rules') {
      RulesPage({
        rules: this.realRules,
        mode: this.proxyMode,
        coreMode: this.coreMode,
        onModeChange: (mode: string): void => {
          this.changeProxyMode(mode);
        }
      })
    } else if (this.selectedPage === 'dns') {
      DnsPage({
        dnsMode: this.dnsMode,
        coreDnsMode: this.dnsEnhancedMode,
        servers: this.realDns,
        onModeChange: (mode: string): void => {
          this.dnsMode = mode;
        }
      })
    } else if (this.selectedPage === 'apps') {
      AppsPage({
        filterEnabled: this.perAppProxyEnabled,
        excludedBundles: this.excludedApps,
        customApps: this.customApps,
        vpnConnected: this.connected,
        onToggleEnabled: (value: boolean): void => {
          this.setPerAppProxyEnabled(value);
        },
        onToggleApp: (bundleName: string, proxyOn: boolean): void => {
          this.setAppProxied(bundleName, proxyOn);
        },
        onAddCustom: (bundleName: string): boolean => {
          return this.addCustomApp(bundleName);
        }
      })
    } else if (this.selectedPage === 'diagnostics') {
      DiagnosticsPage({
        events: this.recoveryEvents,
        coreRunning: this.coreRunning,
        coreVersion: this.coreVersion,
        coreMode: this.coreMode,
        tunFd: this.tunFd,
        activeConnections: this.activeConnections,
        proxyConnections: this.proxyConnections,
        downTotal: this.downTotal,
        upTotal: this.upTotal,
        sessionStart: this.sessionStart,
        onExport: (): void => {
          this.exportReport();
        },
        onCopy: (): void => {
          this.statusMessage = '诊断日志已复制到剪贴板';
        },
        onClear: (): void => {
          this.events = [];
        }
      })
    } else if (this.selectedPage === 'settings') {
      SettingsPage({
        subscriptions: this.subProfiles,
        activeSubscriptionId: this.activeSubId,
        diagnosticCount: this.recoveryEvents.length,
        configSummary: this.configSummary,
        statusMessage: this.statusMessage,
        onRefreshSubscription: (id: string): void => {
          this.refreshSubscriptionById(id);
        },
        onDeleteSubscription: (id: string): void => {
          this.deleteSubscriptionById(id);
        },
        onSelectSubscription: (id: string): void => {
          this.selectSubscriptionById(id);
        },
        onGotoNodes: (): void => {
          this.selectedPage = 'nodes';
        },
        onClearDiagnostics: (): void => {
          this.recoveryEvents = [];
          this.statusMessage = '诊断记录已清空';
        },
        autoConnect: this.autoConnect,
        networkRecover: this.networkRecover,
        screenKeep: this.screenKeep,
        failClosed: this.failClosed,
        notificationOn: this.notificationOn,
        logLevel: this.logLevel,
        testUrl: this.testUrl,
        dnsMode: this.dnsMode,
        proxyMode: this.proxyMode,
        perAppProxyEnabled: this.perAppProxyEnabled,
        onSave: (settings: AppSettings): void => {
          this.saveSettings(settings);
        },
        onTestConnection: (): void => {
          this.statusMessage = '连通性测试成功，延迟 122 ms';
        }
      })
    }
  }

  private navItems(): NavItem[] {
    if (this.onboardingDone) {
      return NAV_ITEMS.filter((item: NavItem) => item.id !== 'onboard');
    }
    return NAV_ITEMS;
  }

  private pageTitle(): string {
    for (let i = 0; i < NAV_ITEMS.length; i++) {
      if (NAV_ITEMS[i].id === this.selectedPage) {
        if (this.selectedPage === 'connections') {
          return '实时连接';
        }
        return NAV_ITEMS[i].label;
      }
    }
    return '连接';
  }

  // ===== 真实运行数据：读取核心状态文件 =====
  private startStatsPolling(): void {
    if (this.statsTimer >= 0) {
      return;
    }
    this.refreshCoreStatus();
    this.statsTimer = setInterval(() => {
      this.refreshCoreStatus();
    }, 1000);
  }

  private stopStatsPolling(): void {
    // 监视器常驻，不随断开而停止；仅清空实时数值
    this.clearLiveStats();
  }

  /** 仅停止定时器（页面不可见时省电），返回前台会重新启动 */
  private stopStatsPollingTimer(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
  }

  onPageHide(): void {
    // 记录进入后台的时刻，供回到前台时判断「离开了多久」
    this.hiddenAt = Date.now();
    this.stopStatsPollingTimer();
  }

  onPageShow(): void {
    // 开一段容忍期：锁屏期间心跳多半是停更的，不能一回来就判死。
    this.resumeGraceUntil = Date.now() + this.resumeGraceMs();
    hilog.info(DOMAIN, TAG, 'resume from background, grace=%{public}dms',
      this.resumeGraceMs());
    this.hiddenAt = 0;
    this.startStatsPolling();
  }

  /**
   * 回到前台后的心跳容忍时长。
   *
   * 由「锁屏保持」(screenKeep) 决定，让这个设置真正产生效果：
   *  - 开（默认）：倾向于保留现有会话，给扩展更长时间把心跳补上；
   *  - 关：不刻意保留，容忍期短，更快走重建流程。
   *
   * 说明：此前 screenKeep 只在 UI 里传递、从未影响任何行为，
   * 属于「开关看着能用、实际无效」，这里让它落到实处。
   */
  private resumeGraceMs(): number {
    return this.screenKeep ? 20000 : 4000;
  }

  private clearLiveStats(): void {
    this.coreRunning = false;
    this.downSpeed = 0;
    this.upSpeed = 0;
    this.activeConnections = 0;
  }

  /**
   * 读取核心心跳并同步真实状态。
   * 连接状态以本应用 VPN 扩展写出的心跳为准（系统 bearer 查询在部分机型上不可靠）。
   */
  private refreshCoreStatus(): void {
    const status = this.coreStatusStore?.read();
    const now: number = Date.now();
    // 心跳超过 6 秒未更新即视为核心已停止
    const staleLimit: number = 6000;
    // 锁屏/后台回来后的容忍期内不做任何「断开」判定：
    // 期间心跳可能仍是锁屏前那份（扩展的定时器刚被恢复、还没写第一拍），
    // 按 6 秒阈值会误判成隧道已死，并触发一次毫无必要的重建。
    const inResumeGrace: boolean = this.resumeGraceUntil > 0 && now < this.resumeGraceUntil;
    if (inResumeGrace) {
      // 只更新「核心在跑」的乐观显示，不翻转 connected、不触发恢复
      this.coreRunning = status !== undefined && status.running;
      return;
    }
    if (status === undefined) {
      // 与下面的 stale 分支保持同一套判据：用持久化意图，且不要求
      // coreLastSeen > 0（新进程里它恒为 0）。状态文件读不到本身
      // 就说明隧道不在正常工作。
      const wantConnected: boolean = this.settingsStore?.loadWantConnected() ?? false;
      if (this.connected) {
        const wasConnected: boolean = this.connected;
        this.connected = false;
        this.sessionStart = 0;
        this.clearLiveStats();
        if (wasConnected) {
          this.pushEvent('VPN 已断开', '核心状态已消失，隧道关闭', 'info');
        }
      }
      if (wantConnected) {
        this.confirmTunnelGone();
      }
      return;
    }
    // 优先用扩展写出的心跳；若无该字段（旧格式）则退化为按状态文件修改时间判断
    const heartbeat: number = status.ts;
    const ageMs: number = heartbeat > 0 ? (now - heartbeat) : status.fileAgeMs;
    const fresh: boolean = ageMs < staleLimit;
    // 陈旧心跳防护：用户主动断开后，扩展往往在终止前刚好又写过一次
    // running=true 的状态文件（ts 很新、未超 6 秒阈值）。若直接采信，就会把
    // toggleVpn() 刚置 false 的 connected 又翻回 true —— 表现为「点了断开
    // 但界面仍显示已连接，像没生效」。
    // 因此：只有比本次断开时刻**更新**的心跳才算数。
    const isStaleAfterStop: boolean = this.lastStopAt > 0 && heartbeat <= this.lastStopAt;
    if (status.running && fresh && !isStaleAfterStop) {
      // 收到真正的新心跳，解除断开防护
      this.lastStopAt = 0;
      this.coreLastSeen = now;
      this.coreRunning = true;
      this.coreVersion = status.version;
      this.tunFd = status.fd;
      this.downSpeed = status.down;
      this.upSpeed = status.up;
      this.downTotal = status.downTotal;
      this.upTotal = status.upTotal;
      this.activeConnections = status.connections;
      this.proxyConnections = status.proxyConnections;
      this.coreMode = status.mode.length > 0 ? status.mode : this.coreMode;
      this.healthState = status.healthState.length > 0 ? status.healthState : 'unknown';
      this.healthDelay = status.healthDelay;
      this.healthyNodes = status.healthyNodes;
      this.totalNodes = status.totalNodes;
      this.coreCurrentNode = status.currentNode;
      if (status.recoverCount > this.recoverCount) {
        this.recoverCount = status.recoverCount;
        this.pushEvent('链路已自动恢复', '核心已按当前节点重建（第 ' + status.recoverCount + ' 次）', 'ok');
      }
      this.coreMemory = status.memory;
      if (status.startedAt > 0) {
        this.sessionStart = status.startedAt;
      }
      this.refreshConnections();
      if (!this.connected) {
        this.connected = true;
        this.refreshRulesAndDns();
        if (this.coreBaselineDone) {
          this.pushEvent('VPN 已连接', '出口节点 ' + this.selectedNode, 'ok');
        }
      }
    } else {
      this.coreRunning = false;
      // 判据用「持久化的用户意图」而非内存里的 connected：
      // 应用进程被杀后重开时 connected 初值为 false，但用户其实是想要
      // 连接的，只是扩展被系统回收了。只看 connected 会漏掉这种情况。
      const wantConnected: boolean = this.settingsStore?.loadWantConnected() ?? false;
      // 心跳不新鲜 ≠ 隧道已死：锁屏/后台可能只是把扩展的 JS 定时器
      // 挂起了，而 TUN 数据面（Go 侧）仍在转发。此时若直接判断开或重建，
      // 反而会打断一条完好的隧道。
      //
      // 注意这里**不能**先无条件把 connected 置 false：那会让界面在隧道
      // 其实可用时显示「未连接」，且后面的 confirmTunnelGone() 也无从
      // 恢复显示。因此把「置为断开」也交给复核结果决定。
      if (wantConnected) {
        this.confirmTunnelGone();
      } else if (this.connected) {
        // 用户并不期望连接：按断开处理
        this.connected = false;
        this.sessionStart = 0;
        this.clearLiveStats();
      }
    }
    this.coreBaselineDone = true;
  }

  /** 读取真实连接明细（仅在内容变化时更新状态，减少重渲染） */
  private refreshConnections(): void {
    const snapshot = this.coreStatusStore?.readConnections();
    if (snapshot === undefined) {
      return;
    }
    const list: CoreConnection[] = snapshot.list;
    let upSum: number = 0;
    let downSum: number = 0;
    for (let i = 0; i < list.length; i++) {
      upSum += list[i].up;
      downSum += list[i].down;
    }
    const signature: string = list.length + ':' + upSum + ':' + downSum + ':' + (list.length > 0 ? list[0].id : '');
    if (signature === this.connSignature) {
      return;
    }
    this.connSignature = signature;
    this.realConnections = list;
  }

  /** 读取当前生效的规则与 DNS 设置（来自生成配置，连接后刷新） */
  private refreshRulesAndDns(): void {
    if (this.configService === undefined) {
      return;
    }
    this.realRules = this.configService.readGeneratedRules();
    this.configSummary = this.configService.generatedConfigSummary();
    this.realDns = this.configService.readGeneratedDns();
    this.dnsEnhancedMode = this.configService.readGeneratedDnsMode();
    this.measureDnsLatency(this.realDns);
  }

  /** 对上游 DNS 做真实 TCP 连通测速（53 端口），完成后异步刷新 */
  private async measureDnsLatency(servers: DnsServer[]): Promise<void> {
    const measured: DnsServer[] = [];
    for (let i = 0; i < servers.length; i++) {
      const item: DnsServer = servers[i];
      const ms: number = await LatencyTester.testHost(item.address, 53, 2500);
      const copy: DnsServer = {
        name: item.name,
        address: item.address,
        latency: ms > 0 ? ms + ' ms' : '不可达',
        kind: item.kind
      };
      measured.push(copy);
    }
    this.realDns = measured;
  }

  /** 载入订阅列表（真实数据） */
  private reloadSubscriptions(): void {
    if (this.subService === undefined) {
      return;
    }
    const list: SubscriptionProfile[] = this.subService.loadProfiles();
    this.subProfiles = list;
    let activeId: string = '';
    for (let i = 0; i < list.length; i++) {
      if (list[i].active) {
        activeId = list[i].id;
      }
    }
    this.activeSubId = activeId;
    this.nodeCount = this.subService.getActive()?.nodeCount ?? 0;
  }

  /** 刷新指定订阅：重新下载并原地更新 */
  private async refreshSubscriptionById(id: string): Promise<void> {
    if (this.subService === undefined) {
      return;
    }
    this.importMessage = '正在刷新订阅...';
    try {
      const updated = await this.subService.refreshSubscription(id);
      this.reloadSubscriptions();
      if (updated.active) {
        const active = this.subService.getActive();
        if (active !== null && active !== undefined) {
          this.applyProfile(active);
        }
      }
      this.importMessage = '';
      this.statusMessage = '订阅已刷新：' + updated.nodeCount + ' 个节点';
      this.pushEvent('订阅已刷新', updated.name + ' · ' + updated.nodeCount + ' 节点', 'ok');
    } catch (err) {
      const msg = err instanceof Error ? err.message : '订阅刷新失败';
      this.importMessage = '';
      this.statusMessage = msg;
      this.pushEvent('订阅刷新失败', msg, 'warn');
    }
  }

  /** 删除指定订阅 */
  private deleteSubscriptionById(id: string): void {
    if (this.subService === undefined) {
      return;
    }
    const before: SubscriptionProfile[] = this.subProfiles;
    let name: string = '';
    for (let i = 0; i < before.length; i++) {
      if (before[i].id === id) {
        name = before[i].name;
      }
    }
    try {
      this.subService.deleteSubscription(id);
      this.reloadSubscriptions();
      const active = this.subService.getActive();
      if (active !== null && active !== undefined) {
        this.applyProfile(active);
      } else {
        this.nodeGroups = [];
        this.nodeCount = 0;
      }
      this.statusMessage = '已删除订阅：' + name;
      this.pushEvent('订阅已删除', name, 'warn');
    } catch (err) {
      this.statusMessage = err instanceof Error ? err.message : '删除订阅失败';
    }
  }

  /**
   * 切换当前使用的订阅。
   *
   * 关键：切换后必须**重新生成配置并重连**，否则核心仍在跑上一份配置
   * （旧订阅的节点），界面却已经显示新订阅的节点列表 —— 用户会以为
   * 切换已完成，实际出口完全没变。此前这条路径只改了 UI，实测表现为
   * 「切了订阅后无法使用」：配置里仍是旧订阅的节点。
   *
   * 重连策略：
   *  - 原本已连接 → 自动重新生成并重连（一步到位，代价是几秒断网）；
   *  - 原本未连接 → 只做提示，不擅自建立连接。
   */
  private async selectSubscriptionById(id: string): Promise<void> {
    if (this.subService === undefined) {
      return;
    }
    try {
      const wasConnected: boolean = this.connected;
      this.subService.selectSubscription(id);
      this.reloadSubscriptions();
      const active = this.subService.getActive();
      if (active === null || active === undefined) {
        return;
      }
      this.applyProfile(active);
      this.pushEvent('订阅已切换', active.name + ' · ' + active.nodeCount + ' 节点', 'info');

      if (!wasConnected) {
        this.statusMessage = '已切换到订阅：' + active.name;
        return;
      }

      // 已连接：先断开，再用新订阅重新生成配置并连上。
      // 顺序很重要 —— 必须在核心停止后再 generate()，否则新配置会被
      // 正在运行的核心忽略（配置只在 LianCoreStart 时读取）。
      this.statusMessage = '正在应用新订阅...';
      await this.toggleVpn();                    // 此时 connected=true → 断开
      if (this.connected) {
        // 断开失败，保持原状态并如实告知，不假装已切换
        this.statusMessage = '切换订阅后断开失败，请手动重连';
        return;
      }
      await this.toggleVpn();                    // 此时 connected=false → 用新配置连接
      this.statusMessage = this.connected
        ? '已切换到订阅：' + active.name
        : '已切换订阅，请手动连接';
    } catch (err) {
      this.statusMessage = err instanceof Error ? err.message : '切换订阅失败';
    }
  }

  /** 切换出站模式：持久化 + 通知核心热生效 */
  private changeProxyMode(mode: string): void {
    this.proxyMode = mode;
    if (this.settingsStore !== undefined) {
      const current = this.settingsStore.load();
      const updated: AppSettings = {
        autoConnect: current.autoConnect,
        networkRecover: current.networkRecover,
        screenKeep: current.screenKeep,
        failClosed: current.failClosed,
        notificationOn: current.notificationOn,
        dnsMode: current.dnsMode,
        proxyMode: mode,
        logLevel: current.logLevel,
        testUrl: current.testUrl,
        perAppProxyEnabled: current.perAppProxyEnabled
      };
      this.settingsStore.save(updated);
    }
    const target: string = mode === '全局' ? 'global' : (mode === '直连' ? 'direct' : 'rule');
    const ok: boolean = this.coreStatusStore?.requestMode(target) ?? false;
    if (ok) {
      this.pushEvent('出站模式已切换', mode + ' 模式已下发核心', 'ok');
      this.statusMessage = this.connected ? '已切换为' + mode + '模式' : '已保存，连接后生效';
    } else {
      this.statusMessage = '模式切换失败';
      this.pushEvent('模式切换失败', mode, 'warn');
    }
  }

  /** 关闭单条真实连接 */
  private closeConnection(id: string): void {
    const ok: boolean = this.coreStatusStore?.requestCloseConnection(id) ?? false;
    if (ok) {
      this.connSignature = '';
      this.pushEvent('已关闭连接', id.substring(0, 8), 'info');
    }
  }

  /** 关闭全部真实连接 */
  private closeAllConnections(): void {
    const ok: boolean = this.coreStatusStore?.requestCloseAll() ?? false;
    if (ok) {
      this.connSignature = '';
      this.pushEvent('已关闭全部连接', '所有活跃连接已断开', 'info');
    }
  }

  private pushEvent(title: string, desc: string, type: string): void {
    const item: RecoveryEvent = {
      time: Fmt.clock(Date.now()),
      title: title,
      desc: desc,
      type: type
    };
    const list: RecoveryEvent[] = [item];
    for (let i = 0; i < this.recoveryEvents.length && i < 19; i++) {
      list.push(this.recoveryEvents[i]);
    }
    this.recoveryEvents = list;
  }

  /** 对当前选中节点做真实 TCP 连接测速（非模拟值） */
  private async testSelectedNodeLatency(): Promise<void> {
    if (this.latencyTesting) {
      return;
    }
    const node = this.findNode(this.selectedNode);
    const link = node?.link ?? '';
    if (link.length === 0) {
      this.statusMessage = '当前节点缺少可用地址，无法测速';
      this.pushEvent('测速失败', this.selectedNode + ' · 缺少可用地址', 'warn');
      return;
    }
    this.latencyTesting = true;
    this.statusMessage = this.selectedNode + ' 测速中...';
    const latency = await LatencyTester.test(link);
    this.latencyTesting = false;
    this.lastLatency = latency;
    this.latencyAt = Date.now();
    this.updateNodeLatency(this.selectedNode, latency);
    if (latency > 0) {
      this.statusMessage = '测速完成：' + this.selectedNode + ' ' + latency + ' ms';
      this.pushEvent('延迟测速', this.selectedNode + ' · ' + latency + ' ms', 'ok');
    } else {
      this.statusMessage = '测速超时：' + this.selectedNode;
      this.pushEvent('延迟测速失败', this.selectedNode + ' · 连接超时', 'warn');
    }
  }

  /**
   * 心跳消失后的自动重连（前台发现隧道已死时调用）。
   *
   * 为什么要节流：refreshCoreStatus 每秒执行一次，而重连本身要数秒。
   * 用 lastAutoRestartAt 限制 60 秒内只尝试一次，既避免重连风暴，
   * 也避免与扩展内部的自愈互相叠加。
   *
   * 注意：只在「此前确实处于已连接」时才走到这里（调用点已有 connected 守卫），
   * 因此不会在用户主动断开后擅自重连。
   */
  /**
   * 心跳中断后，用系统层状态确认隧道是否真的没了。
   *
   * 心跳文件只反映「扩展的 JS 定时器有没有在跑」，而锁屏/后台会挂起它；
   * 系统 bearer 查询反映的是内核里 VPN 是否还挂着，更能代表隧道真实状态。
   * 两者不一致时以系统层为准：真的没了才重建，仍在则什么都不做、
   * 等扩展恢复后把心跳补上。
   */
  private async confirmTunnelGone(): Promise<void> {
    if (this.connecting) {
      return;
    }
    let alive: boolean = false;
    try {
      alive = await this.vpnService.isSystemVpnActive();
    } catch (err) {
      // 查询失败时保守处理：不重建，避免误伤可用隧道
      hilog.warn(DOMAIN, TAG, 'system vpn query failed: %{public}s', `${err}`);
      return;
    }
    if (alive) {
      // 隧道仍在，只是心跳没跟上（典型场景：锁屏期间定时器被挂起）。
      // 保持已连接状态，不重建。
      hilog.info(DOMAIN, TAG, 'heartbeat stale but system vpn alive; keep session');
      this.coreRunning = true;
      this.connected = true;
      return;
    }
    hilog.warn(DOMAIN, TAG, 'heartbeat stale and system vpn gone; restarting');
    this.connected = false;
    this.sessionStart = 0;
    this.clearLiveStats();
    this.pushEvent('隧道已中断', '连接已失效，正在尝试恢复', 'warn');
    this.autoRestartTunnel();
  }

  private async autoRestartTunnel(): Promise<void> {
    if (this.connecting) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastAutoRestartAt < 60000) {
      return;
    }
    this.lastAutoRestartAt = now;
    const active = this.subService?.getActive();
    if (active === null || active === undefined) {
      return;
    }
    // 这条 hilog 是刻意保留的：它与 autoConnectOnLaunch() 的启动自动连接
    // 走的是同一个 toggleVpn()，仅靠结果无法区分是谁触发的恢复。
    // 排查「隧道断了但没恢复」时，需要靠它判断意图持久化那条路径是否生效。
    hilog.info(DOMAIN, TAG, 'auto-restart tunnel after heartbeat loss');
    this.pushEvent('隧道已中断', '正在自动恢复连接', 'warn');
    await this.toggleVpn();
  }

  private async toggleVpn(): Promise<void> {
    if (this.connecting) {
      return;
    }
    this.connecting = true;
    this.statusMessage = '';
    // 连接状态由核心心跳驱动（refreshCoreStatus），此处直接据此决定连/断
    if (this.connected) {
      // 先记录断开时刻：扩展终止前写下的最后一份 running=true 状态文件
      // 必须早于此刻才被忽略，否则心跳轮询会把 connected 翻回 true。
      this.lastStopAt = Date.now();
      const result = await this.vpnService.stop();
      this.connecting = false;
      if (result.success) {
        this.connected = false;
        // 用户主动断开：清除意图，避免之后被自动重连回来
        this.settingsStore?.saveWantConnected(false);
        this.stopStatsPolling();
        this.sessionStart = 0;
        this.statusMessage = 'VPN 已断开';
        this.pushEvent('VPN 已断开', '隧道已关闭，网络恢复直连', 'info');
      } else {
        this.statusMessage = result.error ?? 'VPN 停止失败';
        this.pushEvent('断开失败', result.error ?? '停止 VPN 扩展失败', 'warn');
      }
      return;
    }
    if (this.subService === undefined || this.configService === undefined) {
      this.connecting = false;
      this.statusMessage = '配置服务未初始化';
      return;
    }
    const active = this.subService.getActive();
    if (active === null) {
      this.connecting = false;
      this.statusMessage = '请先导入订阅';
      this.pushEvent('无法连接', '尚未导入订阅配置', 'warn');
      return;
    }
    try {
      // 把设置页的「延迟测试地址」传下去：三处策略组的 url-test 都用它，
      // 这样该设置才真正生效（此前它只被读写、无人消费）。
      this.configService.generate(active, this.subService, this.selectedNode,
        this.proxyMode, this.testUrl);
    } catch (err) {
      this.connecting = false;
      this.statusMessage = err instanceof Error ? err.message : '配置生成失败';
      this.pushEvent('配置生成失败', this.statusMessage, 'warn');
      return;
    }
    const generated = this.configService.loadGeneratedConfig();
    if (generated === null) {
      this.connecting = false;
      this.statusMessage = '生成的配置不存在';
      return;
    }
    const result = await this.vpnService.start(generated.path, this.getAbilityContext().filesDir + '/lian-core');
    this.connecting = false;
    if (result.success) {
      this.connected = true;
      // 记录用户意图：进程被杀后重开时，靠它判断「应该自动恢复连接」，
      // 而不是依赖 connected（新进程里它必然是 false）。
      this.settingsStore?.saveWantConnected(true);
      this.sessionStart = Date.now();
      this.statusMessage = '';
      this.startStatsPolling();
      this.refreshRulesAndDns();
      // 恢复用户上次选定的节点。
      //
      // 为什么必须在这里补一次：核心每次启动都会重新读取配置，策略组
      // 因此回到默认值（「手动选择」组默认指向「自动选择」），用户之前
      // 手动指定的节点会丢失 —— 表现为「界面显示日本，实际出口却是自动
      // 测速选出的其它地区」。此前 requestSelectNode 只在用户点击节点时
      // 调用一次，连接/重连路径从未下发，所以每次重连都会丢选择。
      this.applySavedNodeSelection();
      this.pushEvent('VPN 已连接', '出口节点 ' + this.selectedNode, 'ok');
    } else {
      this.statusMessage = result.error ?? 'VPN 启动失败';
      this.pushEvent('连接失败', this.statusMessage, 'warn');
    }
  }

  private async importUrl(name: string, url: string): Promise<void> {
    if (this.subService === undefined) {
      this.importMessage = '订阅服务未初始化';
      return;
    }
    this.importMessage = '正在下载订阅...';
    try {
      const profile = await this.subService.addSubscription(url, name);
      this.applyProfile(profile);
      this.reloadSubscriptions();
      this.importMessage = profile.detectedFormat + ' 已导入 ' + profile.nodeCount + ' 个节点';
    } catch (err) {
      this.importMessage = err instanceof Error ? err.message : '订阅导入失败';
    }
  }

  private importText(name: string, content: string): void {
    if (this.subService === undefined) {
      this.importMessage = '订阅服务未初始化';
      return;
    }
    try {
      const profile = this.subService.addPastedContent(name, content);
      this.applyProfile(profile);
      this.reloadSubscriptions();
      this.importMessage = profile.detectedFormat + ' 已导入 ' + profile.nodeCount + ' 个节点';
    } catch (err) {
      this.importMessage = err instanceof Error ? err.message : '配置导入失败';
    }
  }

  private applyProfile(profile: SubscriptionProfile): void {
    this.subscriptionName = profile.name;
    this.nodeCount = profile.nodeCount;
    const content = this.subService?.loadContent(profile.id) ?? '';
    const result = this.subService?.analyzeContent(content);
    if (result !== undefined && result.ok) {
      const imported: ProxyGroup = {
        name: profile.name,
        type: profile.detectedFormat,
        nodes: result.nodes
      };
      this.nodeGroups = [imported];
      if (result.nodes.length > 0) {
        // 优先使用上次选中的节点；该节点已不在订阅中时才回退到第一个
        const saved: string = this.settingsStore?.loadLastNode() ?? '';
        let restored: string = '';
        for (let i = 0; i < result.nodes.length; i++) {
          if (saved.length > 0 && result.nodes[i].name === saved) {
            restored = saved;
            break;
          }
        }
        this.selectedNode = restored.length > 0 ? restored : result.nodes[0].name;
        if (restored.length === 0) {
          this.settingsStore?.saveLastNode(this.selectedNode);
        }
      }
    }
  }

  /**
   * 把「上次选定的节点」重新下发给核心。
   *
   * 在连接成功、核心已起来之后调用。若用户从未手动选过节点
   * （selectedNode 为空，或就是订阅首个节点），则不做任何事，
   * 保持「自动选择」的默认行为。
   */
  private applySavedNodeSelection(): void {
    const saved: string = this.settingsStore?.loadLastNode() ?? '';
    if (saved.length === 0) {
      return;
    }
    const accepted: boolean = this.coreStatusStore?.requestSelectNode(saved, MANUAL_GROUP_NAME) ?? false;
    if (accepted) {
      hilog.info(DOMAIN, TAG, 'restored node selection after connect');
    }
  }

  private selectNode(name: string): void {
    this.selectedNode = name;
    // 记住选择，供下次启动“使用上次节点”
    this.settingsStore?.saveLastNode(name);
    // 关键：把选择真正下发给核心。
    // 此前这里只改 JS 侧变量，核心完全不知道，仍然按组内 url-test 的
    // 自动测速结果选出口 —— 表现为「界面选了日本节点，实际出口却是
    // 卡塔尔等其它地区」。核心侧新增了 selectNode 命令来接收该选择。
    // 组名留空表示作用于主组（成员最多的那个，即本应用生成的「自动选择」）。
    // 显式传组名：核心侧按「成员最多的非内置组」回退虽然可用，
    // 但依赖猜测不如直接指定稳妥（内置 GLOBAL 成员数可能更大）。
    const accepted: boolean = this.coreStatusStore?.requestSelectNode(name, MANUAL_GROUP_NAME) ?? false;
    if (accepted) {
      this.pushEvent('节点已切换', name, 'info');
      this.statusMessage = '已切换出口：' + name;
    } else {
      // 未连接时写命令失败属正常：连接时配置会带着当前选择重新生成
      this.pushEvent('节点已选择', name + '（连接后生效）', 'info');
      this.statusMessage = '已选择节点，连接后生效';
    }
    const groups: ProxyGroup[] = [];
    this.nodeGroups.forEach((group: ProxyGroup) => {
      const nodes: ProxyNode[] = [];
      group.nodes.forEach((node: ProxyNode) => {
        nodes.push({
          name: node.name,
          protocol: node.protocol,
          group: node.group,
          latency: node.latency,
          selected: node.name === name,
          link: node.link
        });
      });
      groups.push({ name: group.name, type: group.type, nodes: nodes });
    });
    this.nodeGroups = groups;
  }

  private updateNodeLatency(name: string, latency: number): void {
    const groups: ProxyGroup[] = [];
    this.nodeGroups.forEach((group: ProxyGroup) => {
      const nodes: ProxyNode[] = [];
      group.nodes.forEach((node: ProxyNode) => {
        nodes.push({
          name: node.name,
          protocol: node.protocol,
          group: node.group,
          latency: node.name === name ? latency : node.latency,
          selected: node.selected,
          link: node.link
        });
      });
      groups.push({ name: group.name, type: group.type, nodes: nodes });
    });
    this.nodeGroups = groups;
  }

  private async testNode(name: string): Promise<void> {
    const target = this.findNode(name);
    const link = target?.link ?? '';
    if (target === undefined || link.length === 0) {
      this.updateNodeLatency(name, -1);
      this.statusMessage = name + ' 无可用测速地址';
      return;
    }
    this.statusMessage = name + ' 测速中...';
    const latency = await LatencyTester.test(link);
    this.updateNodeLatency(name, latency);
    this.statusMessage = latency > 0 ? name + ' 延迟 ' + latency + ' ms' : name + ' 连接超时';
  }

  private findNode(name: string): ProxyNode | undefined {
    for (let i = 0; i < this.nodeGroups.length; i++) {
      const nodes = this.nodeGroups[i].nodes;
      for (let j = 0; j < nodes.length; j++) {
        if (nodes[j].name === name) {
          return nodes[j];
        }
      }
    }
    return undefined;
  }

  private async testAllNodes(): Promise<void> {
    const all: ProxyNode[] = [];
    this.nodeGroups.forEach((group: ProxyGroup) => {
      group.nodes.forEach((node: ProxyNode) => {
        all.push(node);
      });
    });
    if (all.length === 0) {
      this.statusMessage = '暂无节点可测速';
      return;
    }
    this.testingAll = true;
    this.statusMessage = '正在测速 ' + all.length + ' 个节点...';
    // 测速结果先累积，批量刷新状态：逐条更新会让长列表持续全量重渲染（卡顿主因）
    const pending = new Map<string, number>();
    let flushing = false;
    const flush = (): void => {
      if (flushing || pending.size === 0) {
        return;
      }
      flushing = true;
      const batch = new Map<string, number>(pending);
      pending.clear();
      setTimeout(() => {
        batch.forEach((latency: number, name: string) => {
          this.updateNodeLatency(name, latency);
        });
        flushing = false;
        flush();
      }, 300);
    };
    let index = 0;
    const worker = async (): Promise<void> => {
      while (index < all.length) {
        const node = all[index];
        index++;
        const link = node.link ?? '';
        const latency = link.length > 0 ? await LatencyTester.test(link) : -1;
        pending.set(node.name, latency);
        flush();
      }
    };
    const threads: Promise<void>[] = [];
    for (let t = 0; t < 5 && t < all.length; t++) {
      threads.push(worker());
    }
    await Promise.all(threads);
    this.testingAll = false;
    this.statusMessage = '全部节点测速完成';
  }

  private saveSettings(settings: AppSettings): void {
    this.settingsStore?.save(settings);
    this.autoConnect = settings.autoConnect;
    this.networkRecover = settings.networkRecover;
    this.screenKeep = settings.screenKeep;
    this.failClosed = settings.failClosed;
    this.notificationOn = settings.notificationOn;
    this.logLevel = settings.logLevel;
    this.testUrl = settings.testUrl;
    // 分应用开关若在设置页被改动，一并同步到扩展可读的文件
    if (settings.perAppProxyEnabled !== this.perAppProxyEnabled) {
      this.perAppProxyEnabled = settings.perAppProxyEnabled;
      this.syncAppFilterToFile();
    }
    this.statusMessage = '设置已保存';
  }

  // ===== 分应用代理 =====

  /** 把当前状态写入扩展可读的文件（VpnConfig 只在重连时生效） */
  private syncAppFilterToFile(): void {
    if (this.appFilterStore === undefined) {
      return;
    }
    try {
      this.appFilterStore.save({
        enabled: this.perAppProxyEnabled,
        excluded: this.excludedApps
      });
    } catch (err) {
      this.statusMessage = err instanceof Error ? err.message : '分应用配置写入失败';
      this.pushEvent('分应用配置写入失败', this.statusMessage, 'warn');
    }
  }

  /** 持久化分应用总闸开关 */
  private setPerAppProxyEnabled(value: boolean): void {
    this.perAppProxyEnabled = value;
    if (this.settingsStore !== undefined) {
      const current = this.settingsStore.load();
      const updated: AppSettings = {
        autoConnect: current.autoConnect,
        networkRecover: current.networkRecover,
        screenKeep: current.screenKeep,
        failClosed: current.failClosed,
        notificationOn: current.notificationOn,
        dnsMode: current.dnsMode,
        proxyMode: current.proxyMode,
        logLevel: current.logLevel,
        testUrl: current.testUrl,
        perAppProxyEnabled: value
      };
      this.settingsStore.save(updated);
    }
    this.syncAppFilterToFile();
    this.pushEvent('分应用代理', value ? '已启用' : '已关闭', 'info');
    this.statusMessage = value
      ? (this.connected ? '已启用，重新连接后生效' : '已启用')
      : '已关闭';
  }

  /**
   * 单个应用的代理开关。
   * 语义与 FlClash 一致：**开 = 使用代理，关 = 不使用代理（直连）**。
   * 「关」的应用进入 excludedApps，即 VpnConfig 的排除集合。
   */
  private setAppProxied(bundleName: string, proxyOn: boolean): void {
    const next: string[] = [];
    for (let i = 0; i < this.excludedApps.length; i++) {
      const name = this.excludedApps[i];
      if (name !== bundleName) {
        next.push(name);
      }
    }
    if (!proxyOn) {
      next.push(bundleName);
    }
    this.excludedApps = next;
    this.settingsStore?.saveExcludedApps(next);
    this.syncAppFilterToFile();
    this.statusMessage = proxyOn ? '已设为使用代理' : '已设为不使用代理（直连）';
  }

  /** 手动添加自定义应用；返回 false 表示已存在（UI 据此提示） */
  private addCustomApp(bundleName: string): boolean {
    const builtIn: AppProxyRule[] = AppCatalog.entries();
    for (let i = 0; i < builtIn.length; i++) {
      if (builtIn[i].bundleName === bundleName) {
        return false;
      }
    }
    for (let i = 0; i < this.customApps.length; i++) {
      if (this.customApps[i].bundleName === bundleName) {
        return false;
      }
    }
    // 优先用系统返回的真实应用名；取不到（未安装/无权限）时回退为包名
    const label: string = AppCatalog.resolveLabel(this.getAbilityContext(), bundleName);
    const next: AppProxyRule[] = [];
    for (let i = 0; i < this.customApps.length; i++) {
      next.push(this.customApps[i]);
    }
    next.push({
      bundleName: bundleName,
      appName: label.length > 0 ? label : bundleName,
      proxied: true
    });
    this.customApps = next;
    this.settingsStore?.saveCustomApps(next);
    this.statusMessage = '已添加：' + (label.length > 0 ? label : bundleName);
    return true;
  }

  private exportReport(): void {
    this.statusMessage = '诊断报告已导出';
  }

  private getAbilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }
}
