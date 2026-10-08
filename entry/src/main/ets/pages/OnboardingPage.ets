import { ContentFrame } from '../common/ContentFrame';

/**
 * 模式选择卡：独立子组件 + @Prop 单向同步。
 *
 * 关键：此前它是 OnboardingPage 里的「带参数 @Builder」，而 ArkUI 中 @Builder
 * 参数按值传递，状态变量改变不会触发其内部 UI 刷新 —— 参数在首次渲染时就被
 * 捕获。于是点击「严格模式」时，onChoice('strict') 确实把父组件的
 * onboardingChoice 改成了 'strict'（状态是对的），但 choiceCard 收到的
 * selected 参数不会重算，绿色高亮与边框始终停在「标准模式」上，表现为
 * 「无法选中严格模式」。
 *
 * 这与 HomePage 的 MetricCard、SettingsPage 的 SubManageRow 是同一修法：
 * 会变化的数据必须由独立子组件的 @Prop 承载，而不是 @Builder 的按值参数。
 */
@Component
struct ChoiceCard {
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop selected: boolean = false;
  value: string = '';
  onPick: (value: string) => void = () => {
  };

  build() {
    Button() {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.selected ? $r('app.color.green') : $r('app.color.text'))
        Text(this.desc)
          .fontSize(10)
          .fontColor($r('app.color.muted'))
          .maxLines(2)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .type(ButtonType.Normal)
    .backgroundColor(this.selected ? $r('app.color.green_soft') : $r('app.color.surface2'))
    .border({ width: 1, color: this.selected ? $r('app.color.green') : $r('app.color.line') })
    .borderRadius(8)
    .height(72)
    .layoutWeight(1)
    .onClick(() => {
      this.onPick(this.value);
    })
  }
}

/**
 * 进度点：与 ChoiceCard 同理，会变化的 active 必须由 @Prop 承载。
 * 原先它是 @Builder dot(active)，靠外层整块重建掩盖了不刷新的问题；
 * 一旦后续改动不再整块重建，进度条就会卡住不动，故一并按同一模式修掉。
 */
@Component
struct ProgressDot {
  @Prop active: boolean = false;

  build() {
    Row()
      .width(24)
      .height(4)
      .borderRadius(2)
      .backgroundColor(this.active ? $r('app.color.green') : $r('app.color.line'))
  }
}

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
        ChoiceCard({
          title: '标准模式',
          desc: '平衡后台稳定性与系统限制',
          selected: this.choice === 'standard',
          value: 'standard',
          onPick: (value: string): void => {
            this.onChoice(value);
          }
        })
        ChoiceCard({
          title: '严格模式',
          desc: '优先阻止直连泄漏',
          selected: this.choice === 'strict',
          value: 'strict',
          onPick: (value: string): void => {
            this.onChoice(value);
          }
        })
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
      ProgressDot({ active: this.step >= 1 })
      ProgressDot({ active: this.step >= 2 })
      ProgressDot({ active: this.step >= 3 })
    }
    .width('100%')
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
