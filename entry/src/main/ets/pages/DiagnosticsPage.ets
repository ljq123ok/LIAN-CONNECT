import { ContentFrame } from '../common/ContentFrame';
import { Fmt } from '../common/Format';
import { RecoveryEvent } from '../models/ArkModels';

@Component
export struct DiagnosticsPage {
  @Prop events: RecoveryEvent[] = [];
  // ===== 真实核心指标 =====
  @Prop coreRunning: boolean = false;
  @Prop coreVersion: string = '';
  @Prop coreMode: string = 'rule';
  @Prop tunFd: number = 0;
  @Prop activeConnections: number = 0;
  @Prop proxyConnections: number = 0;
  @Prop downTotal: number = 0;
  @Prop upTotal: number = 0;
  @Prop sessionStart: number = 0;
  onExport: () => void = () => {
  };
  onCopy: () => void = () => {
  };
  onClear: () => void = () => {
  };

  build() {
    Scroll() {
      ContentFrame() {
      Column({ space: 12 }) {
        this.scorePanel()
        this.stats()
        this.actions()
        this.timeline()
        this.boundary()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 28 })
    }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  private healthLabel(): string {
    return this.coreRunning ? '核心运行中' : '核心未运行';
  }

  private healthDetail(): string {
    if (!this.coreRunning) {
      return 'VPN 未连接，或核心已停止。连接后可查看实时核心指标。';
    }
    const parts: string[] = [];
    parts.push('mihomo ' + this.coreVersion);
    parts.push('TUN fd ' + this.tunFd);
    parts.push(this.coreMode === 'global' ? '全局模式' : (this.coreMode === 'direct' ? '直连模式' : '规则模式'));
    parts.push('已保护 ' + Fmt.duration(Date.now() - this.sessionStart));
    return parts.join(' · ');
  }

  @Builder
  private scorePanel() {
    Row({ space: 14 }) {
      Text(this.coreRunning ? 'OK' : '--')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.coreRunning ? $r('app.color.green') : $r('app.color.muted'))
        .width(72)
        .height(72)
        .textAlign(TextAlign.Center)
        .borderRadius(36)
        .backgroundColor(this.coreRunning ? $r('app.color.green_soft') : $r('app.color.surface2'))
        .border({ width: 2, color: this.coreRunning ? $r('app.color.green') : $r('app.color.line') })
      Column({ space: 4 }) {
        Text(this.healthLabel())
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Text(this.healthDetail())
          .fontSize(11)
          .fontColor($r('app.color.sub'))
          .maxLines(3)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  @Builder
  private stats() {
    Row({ space: 8 }) {
      this.stat('核心运行时间', this.sessionStart > 0 ? Fmt.duration(Date.now() - this.sessionStart) : '—')
      this.stat('活跃连接', this.coreRunning ? '' + this.activeConnections : '—')
    }
    .width('100%')
    Row({ space: 8 }) {
      this.stat('走代理连接', this.coreRunning ? '' + this.proxyConnections : '—')
      this.stat('代理流量', this.coreRunning ? Fmt.bytes(this.downTotal + this.upTotal) : '—')
    }
    .width('100%')
  }

  @Builder
  private stat(label: string, value: string) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(10)
        .fontColor($r('app.color.muted'))
      Text(value)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
    .layoutWeight(1)
  }

  @Builder
  private actions() {
    Row({ space: 8 }) {
      Button('导出报告')
        .type(ButtonType.Normal)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.green_btn_text'))
        .backgroundColor($r('app.color.green'))
        .borderRadius(8)
        .height(38)
        .layoutWeight(1)
        .onClick(this.onExport)
      Button('复制日志')
        .type(ButtonType.Normal)
        .fontSize(12)
        .fontColor($r('app.color.sub'))
        .backgroundColor($r('app.color.surface'))
        .border({ width: 1, color: $r('app.color.line_soft') })
        .borderRadius(8)
        .height(38)
        .layoutWeight(1)
        .onClick(this.onCopy)
      Button('清空')
        .type(ButtonType.Normal)
        .fontSize(12)
        .fontColor($r('app.color.red'))
        .backgroundColor($r('app.color.red_soft'))
        .borderRadius(8)
        .height(38)
        .layoutWeight(1)
        .onClick(this.onClear)
    }
    .width('100%')
  }

  @Builder
  private timeline() {
    Column({ space: 8 }) {
      Row() {
        Text('恢复时间线')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Blank()
        Text('事件驱动')
          .fontSize(11)
          .fontColor($r('app.color.green'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(999)
          .backgroundColor($r('app.color.green_soft'))
      }
      .width('100%')

      Column({ space: 0 }) {
        ForEach(this.events, (event: RecoveryEvent) => {
          this.eventRow(event)
        }, (event: RecoveryEvent) => event.time + event.title)
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
  private eventRow(event: RecoveryEvent) {
    Row({ space: 10 }) {
      Circle({ width: 8, height: 8 })
        .fill(event.type === 'warn' ? $r('app.color.amber') : $r('app.color.green'))
      Column({ space: 2 }) {
        Text(event.title)
          .fontSize(12)
          .fontColor($r('app.color.text'))
        Text(event.desc)
          .fontSize(10)
          .fontColor($r('app.color.muted'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(event.time)
        .fontSize(10)
        .fontColor($r('app.color.muted'))
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  @Builder
  private boundary() {
    Column({ space: 6 }) {
      Text('系统边界')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
        .width('100%')
      Text('用户手动清理应用、系统强杀或极端省电策略下，不承诺自动恢复。启动 VPN 的应用主进程退出时，系统会停止 VPN。')
        .fontSize(11)
        .fontColor($r('app.color.sub'))
        .width('100%')
        .lineHeight(17)
        .padding(12)
        .borderRadius(8)
        .backgroundColor($r('app.color.surface'))
        .border({ width: 1, color: $r('app.color.line_soft') })
    }
    .width('100%')
  }
}
