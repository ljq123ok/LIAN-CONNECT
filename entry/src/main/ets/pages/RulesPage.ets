import { ContentFrame } from '../common/ContentFrame';
import { RuleItem } from '../models/ArkModels';

@Component
export struct RulesPage {
  @Prop rules: RuleItem[] = [];
  @Prop mode: string = '规则';
  /** 核心当前实际生效的模式（rule / global / direct） */
  @Prop coreMode: string = 'rule';
  onModeChange: (mode: string) => void = () => {
  };
  @State private searchText: string = '';

  build() {
    Scroll() {
      ContentFrame() {
      Column({ space: 12 }) {
        this.summary()
        this.modeSelector()
        TextInput({ placeholder: '搜索域名、规则或出口', text: this.searchText })
          .height(42)
          .fontSize(13)
          .fontColor($r('app.color.text'))
          .placeholderColor($r('app.color.muted'))
          .backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.line_soft') })
          .borderRadius(8)
          .onChange((value: string) => {
            this.searchText = value;
          })
        this.list()
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
  private summary() {
    Row({ space: 8 }) {
      this.summaryCell('规则总数', this.rules.length.toString())
      this.summaryCell('代理', this.proxyCount().toString())
      this.summaryCell('直连 / 拒绝', this.directCount().toString())
    }
    .width('100%')
  }

  @Builder
  private summaryCell(label: string, value: string) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(10)
        .fontColor($r('app.color.muted'))
      Text(value)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
    .layoutWeight(1)
  }

  @Builder
  private modeSelector() {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        this.modeButton('全局')
        this.modeButton('规则')
        this.modeButton('直连')
      }
      .width('100%')

      Row() {
        Text('核心当前生效')
          .fontSize(10)
          .fontColor($r('app.color.muted'))
        Blank()
        Text(this.coreModeLabel())
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.green'))
      }
      .width('100%')
    }
    .width('100%')
    .padding(4)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  private coreModeLabel(): string {
    if (this.coreMode === 'global') {
      return '全局模式';
    }
    if (this.coreMode === 'direct') {
      return '直连模式';
    }
    return '规则模式';
  }

  @Builder
  private modeButton(mode: string) {
    Button(mode)
      .type(ButtonType.Normal)
      .fontSize(12)
      .fontColor(this.mode === mode ? $r('app.color.text') : $r('app.color.muted'))
      .backgroundColor(this.mode === mode ? $r('app.color.surface2') : Color.Transparent)
      .border({ width: this.mode === mode ? 1 : 0, color: $r('app.color.line') })
      .borderRadius(6)
      .height(34)
      .layoutWeight(1)
      .onClick(() => {
        this.onModeChange(mode);
      })
  }

  @Builder
  private list() {
    if (this.filteredRules().length === 0) {
      Text('没有匹配的规则')
        .fontSize(12)
        .fontColor($r('app.color.muted'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding(40)
        .borderRadius(8)
        .backgroundColor($r('app.color.surface'))
        .border({ width: 1, color: $r('app.color.line_soft') })
    } else {
      ForEach(this.filteredRules(), (rule: RuleItem) => {
        this.ruleRow(rule)
      }, (rule: RuleItem) => rule.type + rule.payload + rule.proxy)
    }
  }

  private proxyCount(): number {
    return this.rules.filter((rule: RuleItem) => rule.proxy !== 'DIRECT' && rule.proxy !== 'REJECT').length;
  }

  private directCount(): number {
    return this.rules.filter((rule: RuleItem) => rule.proxy === 'DIRECT' || rule.proxy === 'REJECT').length;
  }

  private filteredRules(): RuleItem[] {
    const keyword = this.searchText.trim().toLowerCase();
    return this.rules.filter((rule: RuleItem) =>
      keyword.length === 0 ||
      rule.payload.toLowerCase().indexOf(keyword) >= 0 ||
      rule.proxy.toLowerCase().indexOf(keyword) >= 0 ||
      rule.type.toLowerCase().indexOf(keyword) >= 0);
  }

  @Builder
  private ruleRow(rule: RuleItem) {
    Row({ space: 10 }) {
      Text(rule.type)
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.blue'))
        .padding({ left: 7, right: 7, top: 5, bottom: 5 })
        .borderRadius(6)
        .backgroundColor($r('app.color.blue_soft'))
        .maxLines(1)
      Column({ space: 3 }) {
        Text(rule.payload.length > 0 ? rule.payload : '全部流量')
          .fontSize(12)
          .fontColor($r('app.color.text'))
          .maxLines(1)
        Text('规则序号 ' + (this.rules.indexOf(rule) + 1))
          .fontSize(10)
          .fontColor($r('app.color.muted'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(rule.proxy)
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(rule.proxy === 'DIRECT' ? $r('app.color.cyan') : $r('app.color.green'))
        .maxLines(1)
    }
    .width('100%')
    .padding(10)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }
}
