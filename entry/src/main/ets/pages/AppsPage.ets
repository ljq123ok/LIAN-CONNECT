import { ContentFrame } from '../common/ContentFrame';
import { AppProxyRule } from '../models/ArkModels';
import { AppCatalog } from '../services/AppCatalog';

/** 列表行：应用 + 开关（与 FlClash 一致：关 = 不使用代理） */
@Component
struct AppRow {
  @Prop app: AppProxyRule;
  onToggle: (bundleName: string, proxyOn: boolean) => void = () => {
  };

  build() {
    Row({ space: 10 }) {
      // 图标用首字母块：本工程无法读取其它应用的图标资源
      // （getBundleInfo 被 BMS 拒绝，见 AppCatalog.resolveLabel 的实测日志）。
      Text(this.app.appName.length > 0 ? this.app.appName.substring(0, 1) : '?')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.blue'))
        .width(34)
        .height(34)
        .borderRadius(9)
        .backgroundColor($r('app.color.blue_soft'))
        .textAlign(TextAlign.Center)

      Column({ space: 2 }) {
        Text(this.app.appName)
          .fontSize(13)
          .fontColor($r('app.color.text'))
          .maxLines(1)
        Text(this.app.bundleName)
          .fontSize(9)
          .fontColor($r('app.color.muted'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.app.proxied })
        .selectedColor($r('app.color.green'))
        .onChange((isOn: boolean) => {
          this.onToggle(this.app.bundleName, isOn);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 9, bottom: 9 })
    .border({ width: 1, color: $r('app.color.line_soft') })
  }
}

/**
 * 分应用代理页（FlClash 式）。
 *
 * 交互语义：**开关打开 = 使用代理；关闭 = 不使用代理（直连）**。
 *
 * 列表来源见 AppCatalog 的说明：HarmonyOS 上第三方应用无法枚举已安装应用
 * （需 system_basic 级权限，本机签名 profile 的 acls 为空），因此这里用
 * 「内置常见应用目录 ＋ 任意包名手动添加」，并按包名查询系统信息做校验。
 */
@Component
export struct AppsPage {
  /**
   * 分应用总闸。
   * 命名注意：`enabled` / `toolbar` 等是 ArkUI CustomComponent 的保留成员
   * （`enabled` 是通用属性方法，`toolbar` 是 builder 属性），直接用作
   * @Prop / @Builder 名会与基类签名冲突而编译失败，故统一加 `filter` 前缀。
   */
  @Prop filterEnabled: boolean = false;
  @Prop excludedBundles: string[] = [];
  /** 已加入列表的自定义条目（内置目录之外的包名） */
  @Prop customApps: AppProxyRule[] = [];
  /** 连接中：改设置需重连生效，用于给出提示 */
  @Prop vpnConnected: boolean = false;
  onToggleEnabled: (value: boolean) => void = () => {
  };
  onToggleApp: (bundleName: string, proxyOn: boolean) => void = () => {
  };
  onAddCustom: (bundleName: string) => boolean = () => false;

  @State private keyword: string = '';
  @State private addInput: string = '';
  @State private addError: string = '';
  @State private addMessage: string = '';
  /**
   * 添加区默认展开。
   *
   * 本工程无法枚举已安装应用（见 AppCatalog 类注释），手动录入是唯一的
   * 补充途径，因此不能再把它折叠起来藏在列表底部——那会让用户以为
   * 「列表里没有就是加不了」。默认展开 + 置于列表上方，让入口一眼可见。
   */
  @State private showAdd: boolean = true;

  /** 内置目录 + 自定义条目，合并成一个列表 */
  private allApps(): AppProxyRule[] {
    const out: AppProxyRule[] = [];
    const builtIn: AppProxyRule[] = AppCatalog.entries();
    for (let i = 0; i < builtIn.length; i++) {
      out.push({
        bundleName: builtIn[i].bundleName,
        appName: builtIn[i].appName,
        proxied: this.excludedBundles.indexOf(builtIn[i].bundleName) < 0
      });
    }
    for (let i = 0; i < this.customApps.length; i++) {
      const pkg = this.customApps[i].bundleName;
      // 跳过已在内置目录里的条目：用户可能在某个包进入内置目录之前就手动
      // 添加过它（例如「出境易」）。此时若照搬会产生两条相同 bundleName 的行，
      // 而下面 ForEach 正是以 bundleName 作 key —— 重复 key 会让 ArkUI 行为
      // 未定义（重复渲染 / 复用错行）。内置条目优先，自定义条目只在目录之外
      // 才补进来。
      if (this.isBuiltIn(pkg, builtIn)) {
        continue;
      }
      out.push({
        bundleName: pkg,
        appName: this.customApps[i].appName,
        proxied: this.excludedBundles.indexOf(pkg) < 0
      });
    }
    return out;
  }

  private isBuiltIn(bundleName: string, builtIn: AppProxyRule[]): boolean {
    for (let i = 0; i < builtIn.length; i++) {
      if (builtIn[i].bundleName === bundleName) {
        return true;
      }
    }
    return false;
  }

  private filtered(): AppProxyRule[] {
    const all = this.allApps();
    const kw = this.keyword.trim().toLowerCase();
    if (kw.length === 0) {
      return all;
    }
    const out: AppProxyRule[] = [];
    for (let i = 0; i < all.length; i++) {
      const a = all[i];
      if (a.appName.toLowerCase().indexOf(kw) >= 0 ||
        a.bundleName.toLowerCase().indexOf(kw) >= 0) {
        out.push(a);
      }
    }
    return out;
  }

  private excludedCount(): number {
    return this.excludedBundles.length;
  }

  build() {
    Scroll() {
      ContentFrame() {
        Column({ space: 12 }) {
          this.header()
          if (this.filterEnabled) {
            this.addSection()
            this.filterToolbar()
            this.list()
            this.footnote()
          }
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
  private header() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text('分应用代理')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
          Text('控制哪些应用使用代理')
            .fontSize(10)
            .fontColor($r('app.color.muted'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.filterEnabled })
          .selectedColor($r('app.color.green'))
          .onChange((isOn: boolean) => {
            this.onToggleEnabled(isOn);
          })
      }
      .width('100%')

      Text('开关打开 = 使用代理，关闭 = 不使用代理（直连）。')
        .fontSize(10)
        .fontColor($r('app.color.sub'))
        .width('100%')
        .padding(9)
        .borderRadius(8)
        .backgroundColor($r('app.color.surface2'))

      if (this.filterEnabled && this.vpnConnected) {
        Text('已连接的会话不会自动应用新设置，请断开后重新连接。')
          .fontSize(10)
          .fontColor($r('app.color.amber'))
          .width('100%')
          .padding(9)
          .borderRadius(8)
          .backgroundColor($r('app.color.amber_soft'))
      }
    }
    .width('100%')
  }

  @Builder
  private filterToolbar() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.keyword, placeholder: '搜索应用或包名' })
          .fontSize(12)
          .height(34)
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .onChange((value: string) => {
            this.keyword = value;
          })
        Text(this.excludedCount() + ' 个直连')
          .fontSize(10)
          .fontColor($r('app.color.muted'))
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  private list() {
    Column({ space: 0 }) {
      if (this.filtered().length === 0) {
        // 搜索无结果时引导到手动录入：本工程无法枚举已安装应用，
        // 找不到不代表不能加。只写「没有匹配的应用」会让用户以为到头了。
        Column({ space: 6 }) {
          Text('没有匹配的应用')
            .fontSize(11)
            .fontColor($r('app.color.muted'))
          Text('本机装的应用不在目录里？在上方「添加应用」输入包名即可加入。')
            .fontSize(10)
            .fontColor($r('app.color.blue'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 18, bottom: 18 })
      } else {
        ForEach(this.filtered(), (item: AppProxyRule) => {
          AppRow({
            app: item,
            onToggle: (bundleName: string, proxyOn: boolean): void => {
              this.onToggleApp(bundleName, proxyOn);
            }
          })
        }, (item: AppProxyRule) => item.bundleName)
      }
    }
    .width('100%')
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
    .clip(true)
  }

  @Builder
  private addSection() {
    Column({ space: 8 }) {
      Row() {
        Text('添加应用')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Blank()
        Text(this.showAdd ? '收起' : '展开')
          .fontSize(11)
          .fontColor($r('app.color.blue'))
          .onClick(() => {
            this.showAdd = !this.showAdd;
            this.addError = '';
            this.addMessage = '';
          })
      }
      .width('100%')

      if (this.showAdd) {
        Text('输入包名后添加；支持一次粘贴多个（换行或逗号分隔）。')
          .fontSize(10)
          .fontColor($r('app.color.muted'))
          .width('100%')

        Row({ space: 8 }) {
          TextInput({
            text: this.addInput,
            placeholder: '如 com.example.app，多个用逗号分隔'
          })
            .fontSize(12)
            .height(34)
            .layoutWeight(1)
            .backgroundColor($r('app.color.surface'))
            .onChange((value: string) => {
              this.addInput = value;
              this.addError = '';
              this.addMessage = '';
            })
          Button('添加')
            .type(ButtonType.Normal)
            .fontSize(12)
            .fontColor($r('app.color.blue'))
            .onClick(() => {
              this.submitAdd();
            })
        }
        .width('100%')

        if (this.addError.length > 0) {
          Text(this.addError)
            .fontSize(10)
            .fontColor($r('app.color.red'))
            .width('100%')
        }
        if (this.addMessage.length > 0) {
          Text(this.addMessage)
            .fontSize(10)
            .fontColor($r('app.color.green'))
            .width('100%')
        }
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  /**
   * 提交「添加应用」。
   *
   * 支持一次录入多个包名：逐个校验格式、逐个尝试添加，最后汇总结果。
   * 之所以不做「有一个非法就整体拒绝」：批量粘贴时打错一个字符很常见，
   * 整体回滚会逼用户反复重来；逐条处理并明确报告成功/失败更有用。
   */
  private submitAdd(): void {
    const names: string[] = AppCatalog.parseBundleNames(this.addInput);
    if (names.length === 0) {
      this.addError = '请输入包名（形如 com.example.app）';
      this.addMessage = '';
      return;
    }
    const invalid: string[] = [];
    const existed: string[] = [];
    let added = 0;
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      if (!AppCatalog.isValidBundleName(name)) {
        invalid.push(name);
        continue;
      }
      if (this.onAddCustom(name)) {
        added++;
      } else {
        existed.push(name);
      }
    }
    this.addInput = '';
    const parts: string[] = [];
    if (added > 0) {
      parts.push('已添加 ' + added + ' 个');
    }
    if (existed.length > 0) {
      parts.push(existed.length + ' 个已在列表中');
    }
    if (invalid.length > 0) {
      parts.push(invalid.length + ' 个格式不正确');
    }
    this.addMessage = parts.length > 0 ? parts.join('，') : '';
    // 格式错误单独用红色提示，避免被绿色汇总信息淹没
    this.addError = invalid.length > 0
      ? '格式不正确：' + invalid.join('、')
      : '';
  }

  @Builder
  private footnote() {
    Text('受系统限制，普通应用无法读取「已安装应用」列表（查询与枚举接口均被系统服务拒绝），'
      + '因此这里提供常见应用目录，新装的应用请在「添加应用」中手动输入包名。')
      .fontSize(10)
      .fontColor($r('app.color.muted'))
      .width('100%')
  }
}
