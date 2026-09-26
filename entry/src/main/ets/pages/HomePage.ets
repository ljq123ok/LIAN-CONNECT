import { ContentFrame } from '../common/ContentFrame';
import { Fmt } from '../common/Format';
import { RecoveryEvent } from '../models/ArkModels';

/** 依据色调关键字取色，避免把 ResourceColor 当作 @Prop 传递 */
function toneColor(tone: string): ResourceColor {
  if (tone === 'blue') {
    return $r('app.color.blue');
  }
  if (tone === 'green') {
    return $r('app.color.green');
  }
  if (tone === 'amber') {
    return $r('app.color.amber');
  }
  if (tone === 'cyan') {
    return $r('app.color.cyan');
  }
  return $r('app.color.text');
}

/**
 * 指标卡：独立子组件 + @Prop 单向同步。
 * 关键：不要用「带参数的 @Builder」承载会变化的数据——ArkUI 中 @Builder
 * 参数按值传递，状态变量改变不会触发其内部 UI 刷新（会表现为数字卡住不动）。
 */
@Component
struct MetricCard {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop detail: string = '';
  @Prop tone: string = 'text';

  build() {
    Column({ space: 6 }) {
      Text(this.label)
        .fontSize(11)
        .fontColor($r('app.color.muted'))
      Text(this.value)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(toneColor(this.tone))
        .maxLines(1)
      Text(this.detail)
        .fontSize(10)
        .fontColor($r('app.color.muted'))
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
    .layoutWeight(1)
  }
}

/** 链路状态行 */
@Component
struct HealthRow {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(12)
        .fontColor($r('app.color.sub'))
      Blank()
      Text(this.value)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text'))
        .maxLines(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
  }
}

/** 事件行 */
@Component
struct EventRow {
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop time: string = '';
  @Prop tone: string = 'green';

  build() {
    Row() {
      Circle({ width: 8, height: 8 })
        .fill(toneColor(this.tone))
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(12)
          .fontColor($r('app.color.text'))
          .maxLines(1)
        Text(this.desc)
          .fontSize(10)
          .fontColor($r('app.color.muted'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })
      Text(this.time)
        .fontSize(10)
        .fontColor($r('app.color.muted'))
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .border({ width: { bottom: 1 }, color: $r('app.color.line_soft') })
  }
}

/** 快捷操作按钮 */
@Component
struct ActionButton {
  @Prop label: string = '';
  onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .type(ButtonType.Normal)
      .fontSize(11)
      .fontColor($r('app.color.sub'))
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.line_soft') })
      .borderRadius(8)
      .height(58)
      .layoutWeight(1)
      .onClick(() => {
        this.onTap();
      })
  }
}

@Component
export struct HomePage {
  @Prop connected: boolean = false;
  @Prop connecting: boolean = false;
  @Prop selectedNode: string = '';
  @Prop nodeCount: number = 0;
  @Prop statusMessage: string = '';
  // ===== 真实运行数据（全部来自 mihomo 核心状态与会话状态）=====
  @Prop coreRunning: boolean = false;
  @Prop coreVersion: string = '';
  @Prop tunFd: number = 0;
  @Prop downSpeed: number = 0;
  @Prop upSpeed: number = 0;
  @Prop downTotal: number = 0;
  @Prop upTotal: number = 0;
  @Prop activeConnections: number = 0;
  @Prop sessionStart: number = 0;
  @Prop lastLatency: number = -1;
  @Prop latencyAt: number = 0;
  @Prop latencyTesting: boolean = false;
  @Prop dnsMode: string = '智能';
  @Prop proxyMode: string = '规则';
  @Prop healthState: string = 'unknown';
  @Prop healthDelay: number = 0;
  @Prop healthyNodes: number = 0;
  @Prop totalNodes: number = 0;
  @Prop recoverCount: number = 0;
  @Prop recoveryEvents: RecoveryEvent[] = [];
  onToggle: () => void = () => {
  };
  onGotoNodes: () => void = () => {
  };
  onGotoDiagnostics: () => void = () => {
  };
  onTestLatency: () => void = () => {
  };
  onExport: () => void = () => {
  };

  build() {
    Scroll() {
      ContentFrame() {
      Column({ space: 14 }) {
        this.hero()
        this.metrics()
        this.health()
        this.events()
        this.quickActions()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 28 })
    }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  /** 隧道是否真的通（核心存活 + 健康探测未失败） */
  private tunnelOk(): boolean {
    return this.connected && this.healthState !== 'fail';
  }

  private heroTitle(): string {
    if (!this.connected) {
      return this.connecting ? '正在连接' : '未连接';
    }
    if (this.healthState === 'fail') {
      return '链路异常';
    }
    return '已连接';
  }

  private heroHint(): string {
    if (!this.connected) {
      return this.connecting ? '正在建立隧道' : '等待连接';
    }
    if (this.healthState === 'fail') {
      return '出口不可达 · 正在自动恢复';
    }
    if (this.healthState === 'unknown') {
      return '流量已保护 · 健康探测中';
    }
    return '流量已保护';
  }

  private heroColor(): ResourceColor {
    if (!this.connected) {
      return this.connecting ? $r('app.color.amber') : $r('app.color.text');
    }
    if (this.healthState === 'fail') {
      return $r('app.color.red');
    }
    return $r('app.color.green');
  }

  @Builder
  private hero() {
    Column({ space: 12 }) {
      Button('VPN')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.connected ? $r('app.color.green_btn_text') : $r('app.color.sub'))
      .type(ButtonType.Circle)
      .width(126)
      .height(126)
      .backgroundColor(this.tunnelOk() ? $r('app.color.green') : (this.connected ? $r('app.color.amber') : (this.connecting ? $r('app.color.amber') : $r('app.color.surface2'))))
      .border({ width: 1, color: this.tunnelOk() ? $r('app.color.green') : $r('app.color.line') })
      .onClick(this.onToggle)

      Text(this.heroHint())
        .fontSize(12)
        .fontColor($r('app.color.muted'))
      Text(this.heroTitle())
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.heroColor())
      Text(this.selectedNode.length > 0 ? '出口节点 ' + this.selectedNode : '未选择节点')
        .fontSize(13)
        .fontColor($r('app.color.sub'))
      if (this.statusMessage.length > 0) {
        Text(this.statusMessage)
          .fontSize(11)
          .fontColor($r('app.color.red'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
      }
    }
    .width('100%')
    .padding({ top: 16, bottom: 12 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private metrics() {
    Row({ space: 10 }) {
      MetricCard({
        label: '下行',
        value: this.connected ? Fmt.speed(this.downSpeed) : '—',
        detail: '累计 ' + Fmt.bytes(this.downTotal),
        tone: 'blue'
      })
      MetricCard({
        label: '上行',
        value: this.connected ? Fmt.speed(this.upSpeed) : '—',
        detail: '累计 ' + Fmt.bytes(this.upTotal),
        tone: 'green'
      })
    }
    .width('100%')

    Row({ space: 10 }) {
      MetricCard({
        label: '当前延迟',
        value: Fmt.latency(this.lastLatency),
        detail: this.latencyTesting ? '测速中...' : Fmt.ago(this.latencyAt),
        tone: 'amber'
      })
      MetricCard({
        label: '活跃连接',
        value: this.connected ? '' + this.activeConnections : '—',
        detail: this.sessionStart > 0 ? '已保护 ' + Fmt.duration(Date.now() - this.sessionStart) : '未保护',
        tone: 'cyan'
      })
    }
    .width('100%')
  }

  @Builder
  private health() {
    Column({ space: 8 }) {
      Row() {
        Text('链路状态')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Blank()
        Text(this.coreRunning ? (this.healthState === 'fail' ? '链路异常' : '核心运行中') : (this.connected ? '核心启动中' : '未启用'))
          .fontSize(11)
          .fontColor(this.coreRunning && this.healthState !== 'fail' ? $r('app.color.green') : $r('app.color.amber'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(999)
          .backgroundColor(this.coreRunning && this.healthState !== 'fail' ? $r('app.color.green_soft') : $r('app.color.amber_soft'))
      }
      .width('100%')

      Column() {
        HealthRow({ label: 'VPN 会话', value: this.connected ? '已建立' : '等待连接' })
        HealthRow({ label: 'TUN 设备', value: this.tunFd > 0 ? 'vpn-tun · fd ' + this.tunFd : 'vpn-tun' })
        HealthRow({ label: '核心版本', value: this.coreVersion.length > 0 ? 'mihomo ' + this.coreVersion : '未运行' })
        HealthRow({ label: 'DNS 策略', value: this.dnsMode + ' · redir-host' })
        HealthRow({ label: '出站模式', value: this.proxyMode })
        HealthRow({ label: '网络保护', value: this.connected ? 'protectProcessNet 已启用' : '未启用' })
        HealthRow({ label: '出口可达性', value: this.healthLabel() })
        HealthRow({ label: '可用节点', value: this.connected && this.totalNodes > 0 ? (this.healthyNodes + ' / ' + this.totalNodes) : '—' })
        HealthRow({ label: '自动恢复', value: this.recoverCount > 0 ? '已自愈 ' + this.recoverCount + ' 次' : '未触发' })
      }
      .width('100%')
      .borderRadius(8)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.line_soft') })
      .clip(true)
    }
    .width('100%')
  }

  private healthLabel(): string {
    if (!this.connected) {
      return '—';
    }
    if (this.healthState === 'fail') {
      return '不可达';
    }
    if (this.healthState === 'ok') {
      return this.healthDelay > 0 ? '正常 · ' + this.healthDelay + ' ms' : '正常';
    }
    return '探测中';
  }

  private eventTone(type: string): string {
    if (type === 'warn') {
      return 'amber';
    }
    if (type === 'info') {
      return 'blue';
    }
    return 'green';
  }

  @Builder
  private events() {
    Column({ space: 8 }) {
      Row() {
        Text('最近事件')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Blank()
        Button('查看全部')
          .type(ButtonType.Normal)
          .fontSize(12)
          .fontColor($r('app.color.blue'))
          .onClick(this.onGotoDiagnostics)
      }
      .width('100%')

      Column({ space: 0 }) {
        if (this.recoveryEvents.length === 0) {
          Row() {
            Text('暂无事件记录 · 连接、断开、测速会实时记录在这里')
              .fontSize(11)
              .fontColor($r('app.color.muted'))
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 14, bottom: 14 })
        } else {
          ForEach(this.recoveryEvents, (ev: RecoveryEvent, index: number) => {
            EventRow({
              title: ev.title,
              desc: ev.desc,
              time: ev.time,
              tone: this.eventTone(ev.type)
            })
          }, (ev: RecoveryEvent, index: number) => ev.time + '-' + ev.title + '-' + index)
        }
      }
      .width('100%')
      .borderRadius(8)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.line_soft') })
      .clip(true)
    }
    .width('100%')
  }

  @Builder
  private quickActions() {
    Row({ space: 8 }) {
      ActionButton({
        label: this.latencyTesting ? '测速中' : '测速',
        onTap: this.onTestLatency
      })
      ActionButton({
        label: '切换节点',
        onTap: this.onGotoNodes
      })
      ActionButton({
        label: '导出诊断',
        onTap: this.onExport
      })
    }
    .width('100%')
  }
}
