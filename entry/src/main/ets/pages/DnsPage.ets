import { ContentFrame } from '../common/ContentFrame';
import { DnsServer } from '../models/ArkModels';

@Component
export struct DnsPage {
  @Prop dnsMode: string = '智能';
  /** 核心实际生效的 DNS 增强模式（如 redir-host） */
  @Prop coreDnsMode: string = '';
  @Prop servers: DnsServer[] = [];
  @Prop dnsCache: boolean = true;
  @Prop fakeIp: boolean = false;
  @Prop sniff: boolean = true;
  @Prop failClosed: boolean = false;
  onSettingsChange: (mode: string, dnsCache: boolean, fakeIp: boolean,
    sniff: boolean, failClosed: boolean) => void = () => {
  };

  build() {
    Scroll() {
      ContentFrame() {
      Column({ space: 12 }) {
        this.modeSelector()
        if (this.dnsMode === '直连') {
          Text('直连模式可能使用系统 DNS，建议确认下方防泄漏开关')
            .fontSize(11)
            .fontColor($r('app.color.amber'))
            .width('100%')
            .padding(10)
            .borderRadius(8)
            .backgroundColor($r('app.color.amber_soft'))
        }
        this.serverList()
        this.settingGroup('解析策略')
        this.settingGroup('防泄漏')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 28 })
    }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  private modeSelector() {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        this.modeButton('智能')
        this.modeButton('Fake-IP')
        this.modeButton('直连')
      }
      .width('100%')

      Row() {
        Text('核心当前解析模式')
          .fontSize(10)
          .fontColor($r('app.color.muted'))
        Blank()
        Text(this.coreDnsMode.length > 0 ? this.coreDnsMode : '未连接')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.coreDnsMode.length > 0 ? $r('app.color.green') : $r('app.color.muted'))
      }
      .width('100%')
    }
    .width('100%')
    .padding(4)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  @Builder
  private modeButton(mode: string) {
    Button(mode)
      .type(ButtonType.Normal)
      .fontSize(12)
      .fontColor(this.dnsMode === mode ? $r('app.color.text') : $r('app.color.muted'))
      .backgroundColor(this.dnsMode === mode ? $r('app.color.surface2') : Color.Transparent)
      .border({ width: this.dnsMode === mode ? 1 : 0, color: $r('app.color.line') })
      .borderRadius(6)
      .height(34)
      .layoutWeight(1)
      .onClick(() => {
        this.onSettingsChange(mode, this.dnsCache, mode === 'Fake-IP', this.sniff, this.failClosed);
      })
  }

  @Builder
  private serverList() {
    Column({ space: 8 }) {
      ForEach(this.servers, (server: DnsServer) => {
        Row({ space: 10 }) {
          Text(server.name.substring(0, 1).toUpperCase())
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.cyan'))
            .width(36)
            .height(36)
            .borderRadius(8)
            .backgroundColor($r('app.color.cyan_soft'))
            .textAlign(TextAlign.Center)
          Column({ space: 3 }) {
            Text(server.name)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text'))
            Text(server.address)
              .fontSize(10)
              .fontColor($r('app.color.muted'))
              .maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Column({ space: 2 }) {
            Text(server.latency)
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.green'))
            Text(server.kind)
              .fontSize(10)
              .fontColor($r('app.color.muted'))
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .padding(10)
        .borderRadius(8)
        .backgroundColor($r('app.color.surface'))
        .border({ width: 1, color: $r('app.color.line_soft') })
      }, (server: DnsServer) => server.name)
    }
    .width('100%')
  }

  @Builder
  private settingGroup(title: string) {
    Column({ space: 0 }) {
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.sub'))
        .width('100%')
        .margin({ bottom: 8 })
      Column({ space: 0 }) {
        this.switchRow('DNS 缓存', '已解析域名缓存 300 秒', this.dnsCache, (value: boolean) => {
          this.onSettingsChange(this.dnsMode, value, this.fakeIp, this.sniff, this.failClosed);
        })
        if (title === '解析策略') {
          this.switchRow('Fake-IP', '返回 198.18.0.0/16 虚拟地址', this.fakeIp, (value: boolean) => {
            this.onSettingsChange(value ? 'Fake-IP' : '智能', this.dnsCache, value,
              this.sniff, this.failClosed);
          })
          this.switchRow('流量嗅探', '识别未加密流量的目标域名', this.sniff, (value: boolean) => {
            this.onSettingsChange(this.dnsMode, this.dnsCache, this.fakeIp, value, this.failClosed);
          })
        } else {
          this.switchRow('DNS 防泄漏', '核心或 DNS 异常时阻止直连', this.failClosed, (value: boolean) => {
            this.onSettingsChange(this.dnsMode, this.dnsCache, this.fakeIp, this.sniff, value);
          })
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
  private switchRow(title: string, desc: string, checked: boolean, onChange: (value: boolean) => void) {
    Row() {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(12)
          .fontColor($r('app.color.text'))
        Text(desc)
          .fontSize(10)
          .fontColor($r('app.color.muted'))
          .maxLines(2)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor($r('app.color.green'))
        .onChange((value: boolean) => {
          onChange(value);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .border({ width: 1, color: $r('app.color.line_soft') })
  }
}
