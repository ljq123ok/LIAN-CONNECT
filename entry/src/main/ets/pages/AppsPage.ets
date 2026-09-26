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
  @State private showAdd: boolean = false;

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
      out.push({
        bundleName: this.customApps[i].bundleName,
        appName: this.customApps[i].appName,
        proxied: this.excludedBundles.indexOf(this.customApps[i].bundleName) < 0
      });
    }
    return out;
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
            this.filterToolbar()
            this.list()
            this.addSection()
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
        Text('没有匹配的应用')
          .fontSize(11)
          .fontColor($r('app.color.muted'))
          .width('100%')
          .padding({ top: 18, bottom: 18 })
          .textAlign(TextAlign.Center)
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
        Text('添加其它应用')
          .fontSize(11)
          .fontColor($r('app.color.sub'))
        Blank()
        Text(this.showAdd ? '收起' : '展开')
          .fontSize(11)
          .fontColor($r('app.color.blue'))
          .onClick(() => {
            this.showAdd = !this.showAdd;
            this.addError = '';
          })
      }
      .width('100%')

      if (this.showAdd) {
        Row({ space: 8 }) {
          TextInput({ text: this.addInput, placeholder: '输入包名，如 com.example.app' })
            .fontSize(12)
            .height(34)
            .layoutWeight(1)
            .backgroundColor($r('app.color.surface'))
            .onChange((value: string) => {
              this.addInput = value;
              this.addError = '';
            })
          Button('添加')
            .type(ButtonType.Normal)
            .fontSize(12)
            .fontColor($r('app.color.blue'))
            .onClick(() => {
              const name = this.addInput.trim();
              if (!AppCatalog.isValidBundleName(name)) {
                this.addError = '包名格式不正确（需形如 com.example.app）';
                return;
              }
              const ok = this.onAddCustom(name);
              if (ok) {
                this.addInput = '';
                this.addError = '';
              } else {
                this.addError = '该包名已在列表中';
              }
            })
        }
        .width('100%')

        if (this.addError.length > 0) {
          Text(this.addError)
            .fontSize(10)
            .fontColor($r('app.color.red'))
            .width('100%')
        }
      }
    }
    .width('100%')
  }

  @Builder
  private footnote() {
    Text('系统未向普通应用开放「读取已安装应用」的能力（查询与枚举接口均被系统服务拒绝），'
      + '因此这里提供常见应用目录，并可手动输入包名。')
      .fontSize(10)
      .fontColor($r('app.color.muted'))
      .width('100%')
  }
}
