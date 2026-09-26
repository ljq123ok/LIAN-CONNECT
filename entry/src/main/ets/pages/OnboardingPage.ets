import { ContentFrame } from '../common/ContentFrame';

@Component
export struct OnboardingPage {
  @Prop step: number = 1;
  @Prop choice: string = 'standard';
  onNext: () => void = () => {
  };
  onPrev: () => void = () => {
  };
  onFinish: () => void = () => {
  };
  onChoice: (choice: string) => void = () => {
  };

  build() {
    Scroll() {
      ContentFrame() {
      Column({ space: 14 }) {
        if (this.step === 1) {
          this.welcome()
        } else if (this.step === 2) {
          this.subscriptionStep()
        } else {
          this.permissionStep()
        }
        this.progress()
        this.navigation()
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
  private welcome() {
    Column({ space: 10 }) {
      Text('盾')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.green'))
        .width(48)
        .height(48)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor($r('app.color.green_soft'))
      Text('欢迎使用 LIAN CONNECT')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
      Text('使用鸿蒙原生 VpnExtensionAbility 建立系统级隧道，核心内嵌，不依赖外置进程和模拟保活。')
        .fontSize(12)
        .fontColor($r('app.color.sub'))
        .lineHeight(19)
      Row({ space: 8 }) {
        this.choiceCard('标准模式', '平衡后台稳定性与系统限制', this.choice === 'standard', 'standard')
        this.choiceCard('严格模式', '优先阻止直连泄漏', this.choice === 'strict', 'strict')
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private subscriptionStep() {
    Column({ space: 10 }) {
      Text('订阅')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.blue'))
        .width(48)
        .height(48)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor($r('app.color.blue_soft'))
      Text('导入订阅')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
      Text('粘贴订阅链接后，LIAN CONNECT 会解析节点列表并保存一份可离线使用的配置快照。')
        .fontSize(12)
        .fontColor($r('app.color.sub'))
        .lineHeight(19)
      Text('支持 Clash / Mihomo YAML、Base64 订阅和分享链接。')
        .fontSize(11)
        .fontColor($r('app.color.green'))
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(8)
        .backgroundColor($r('app.color.green_soft'))
    }
    .width('100%')
    .padding(14)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private permissionStep() {
    Column({ space: 10 }) {
      Text('授权')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.amber'))
        .width(48)
        .height(48)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor($r('app.color.amber_soft'))
      Text('系统授权')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
      Text('连接 VPN 前，需要确认以下系统能力。LIAN CONNECT 不会申请长时任务或使用模拟保活。')
        .fontSize(12)
        .fontColor($r('app.color.sub'))
        .lineHeight(19)
      this.permissionRow('建立 VPN 隧道', '系统级 VPN，接管网络并保护应用流量')
      this.permissionRow('监听默认网络', 'Wi-Fi 与蜂窝切换时迁移出站连接')
      this.permissionRow('保护扩展进程', 'API 22+ 调用 protectProcessNet()')
    }
    .width('100%')
    .padding(14)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private choiceCard(title: string, desc: string, selected: boolean, value: string) {
    Button() {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(selected ? $r('app.color.green') : $r('app.color.text'))
        Text(desc)
          .fontSize(10)
          .fontColor($r('app.color.muted'))
          .maxLines(2)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .type(ButtonType.Normal)
    .backgroundColor(selected ? $r('app.color.green_soft') : $r('app.color.surface2'))
    .border({ width: 1, color: selected ? $r('app.color.green') : $r('app.color.line') })
    .borderRadius(8)
    .height(72)
    .layoutWeight(1)
    .onClick(() => {
      this.onChoice(value);
    })
  }

  @Builder
  private permissionRow(title: string, desc: string) {
    Row({ space: 10 }) {
      Text('√')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.blue'))
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor($r('app.color.blue_soft'))
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
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: $r('app.color.line_soft') })
  }

  @Builder
  private progress() {
    Row({ space: 6 }) {
      this.dot(this.step >= 1)
      this.dot(this.step >= 2)
      this.dot(this.step >= 3)
    }
    .width('100%')
  }

  @Builder
  private dot(active: boolean) {
    Row()
      .width(24)
      .height(4)
      .borderRadius(2)
      .backgroundColor(active ? $r('app.color.green') : $r('app.color.line'))
  }

  @Builder
  private navigation() {
    Row({ space: 8 }) {
      if (this.step > 1) {
        Button('上一步')
          .type(ButtonType.Normal)
          .fontSize(12)
          .fontColor($r('app.color.sub'))
          .backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.line_soft') })
          .borderRadius(8)
          .height(40)
          .layoutWeight(1)
          .onClick(this.onPrev)
      }
      Button(this.step === 3 ? '完成' : '下一步')
        .type(ButtonType.Normal)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.green_btn_text'))
        .backgroundColor($r('app.color.green'))
        .borderRadius(8)
        .height(40)
        .layoutWeight(1)
        .onClick(this.step === 3 ? this.onFinish : this.onNext)
    }
    .width('100%')
  }
}
