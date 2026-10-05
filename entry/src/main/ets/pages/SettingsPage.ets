import { ContentFrame } from '../common/ContentFrame';
import { AppSettings, SubscriptionProfile } from '../models/ArkModels';

/** 订阅管理行：独立子组件，保证 @Prop 变化能实时刷新（@Builder 按值传参不会刷新） */
@Component
struct SubManageRow {
  @Prop subId: string = '';
  @Prop name: string = '';
  @Prop format: string = '';
  @Prop nodeCount: number = 0;
  @Prop updatedAt: string = '';
  @Prop active: boolean = false;
  onRefresh: (id: string) => void = () => {
  };
  onDelete: (id: string) => void = () => {
  };
  onSelect: (id: string) => void = () => {
  };

  private timeLabel(): string {
    if (this.updatedAt.length < 16) {
      return this.updatedAt;
    }
    return this.updatedAt.substring(5, 16).replace('T', ' ');
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.name)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
          .maxLines(1)
          .layoutWeight(1)
        if (this.active) {
          Text('当前')
            .fontSize(10)
            .fontColor($r('app.color.green'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(999)
            .backgroundColor($r('app.color.green_soft'))
        }
      }
      .width('100%')

      Text(this.format + ' · ' + this.nodeCount + ' 节点 · 更新于 ' + this.timeLabel())
        .fontSize(10)
        .fontColor($r('app.color.muted'))
        .maxLines(1)
        .width('100%')

      Row({ space: 8 }) {
        if (!this.active) {
          Button('设为当前')
            .type(ButtonType.Normal)
            .fontSize(11)
            .fontColor($r('app.color.green'))
            .backgroundColor($r('app.color.green_soft'))
            .borderRadius(6)
            .height(30)
            .onClick(() => {
              this.onSelect(this.subId);
            })
        }
        Button('刷新')
          .type(ButtonType.Normal)
          .fontSize(11)
          .fontColor($r('app.color.blue'))
          .backgroundColor($r('app.color.blue_soft'))
          .borderRadius(6)
          .height(30)
          .onClick(() => {
            this.onRefresh(this.subId);
          })
        Button('删除')
          .type(ButtonType.Normal)
          .fontSize(11)
          .fontColor($r('app.color.red'))
          .backgroundColor($r('app.color.red_soft'))
          .borderRadius(6)
          .height(30)
          .onClick(() => {
            this.onDelete(this.subId);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }
}

/** 一行「说明 + 操作按钮」，点击真实回调 */
@Component
struct SettingActionRow {
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop actionLabel: string = '';
  onAction: () => void = () => {
  };

  build() {
    Row() {
      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(12)
          .fontColor($r('app.color.text'))
        Text(this.desc)
          .fontSize(10)
          .fontColor($r('app.color.muted'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button(this.actionLabel)
        .type(ButtonType.Normal)
        .fontSize(12)
        .fontColor($r('app.color.blue'))
        .onClick(() => {
          this.onAction();
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .border({ width: 1, color: $r('app.color.line_soft') })
  }
}

@Component
export struct SettingsPage {
  @Prop autoConnect: boolean = true;
  @Prop networkRecover: boolean = true;
  @Prop screenKeep: boolean = true;
  @Prop failClosed: boolean = false;
  @Prop notificationOn: boolean = true;
  @Prop logLevel: string = 'info';
  @Prop testUrl: string = 'https://www.gstatic.com/generate_204';
  /**
   * 当前生效的 DNS / 出站模式与分应用开关。
   * 必须由父组件传入：`buildSettings()` 会整体重建 AppSettings，
   * 之前这里写死为 '智能'/'规则'，导致「在设置页保存一次」就把用户
   * 选过的 DNS 与出站模式重置掉。
   */
  @Prop dnsMode: string = '智能';
  @Prop proxyMode: string = '规则';
  @Prop perAppProxyEnabled: boolean = false;
  onSave: (settings: AppSettings) => void = () => {
  };
  onTestConnection: () => void = () => {
  };
  // ===== 真实数据：订阅管理 / 配置摘要 / 诊断记录 =====
  @Prop subscriptions: SubscriptionProfile[] = [];
  @Prop activeSubscriptionId: string = '';
  @Prop diagnosticCount: number = 0;
  @Prop configSummary: string = '';
  /** 操作反馈（刷新/删除/切换订阅的结果） */
  @Prop statusMessage: string = '';
  onRefreshSubscription: (id: string) => void = () => {
  };
  onDeleteSubscription: (id: string) => void = () => {
  };
  onSelectSubscription: (id: string) => void = () => {
  };
  onGotoNodes: () => void = () => {
  };
  onClearDiagnostics: () => void = () => {
  };

  @State private showSubManager: boolean = false;
  @State private showConfigDetail: boolean = false;

  @State private localAutoConnect: boolean = true;
  @State private localNetworkRecover: boolean = true;
  @State private localScreenKeep: boolean = true;
  @State private localFailClosed: boolean = false;
  @State private localNotificationOn: boolean = true;
  @State private localLogLevel: string = 'info';
  @State private localTestUrl: string = '';

  aboutToAppear(): void {
    this.localAutoConnect = this.autoConnect;
    this.localNetworkRecover = this.networkRecover;
    this.localScreenKeep = this.screenKeep;
    this.localFailClosed = this.failClosed;
    this.localNotificationOn = this.notificationOn;
    this.localLogLevel = this.logLevel;
    this.localTestUrl = this.testUrl;
  }

  build() {
    Scroll() {
      ContentFrame() {
      Column({ space: 12 }) {
        this.settingGroup('连接行为')
        this.coreGroup()
        this.dataGroup()
        this.aboutGroup()
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
  private settingGroup(title: string) {
    Column({ space: 0 }) {
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.sub'))
        .width('100%')
        .margin({ bottom: 8 })
      Column({ space: 0 }) {
        // 每个开关改动后立即落盘。
        // 原先这里只改本地 @State，而 SettingsPage.save() 没有任何调用方
        // （死代码），导致「关闭启动时自动连接」等操作实际上从未保存，
        // 重启应用后依旧按默认值(true)行为 —— 开关看起来能用，其实无效。
        this.switchRow('启动时自动连接', '应用启动后使用上次节点', this.localAutoConnect, (value: boolean) => {
          this.localAutoConnect = value;
          this.save();
        })
        this.switchRow('网络切换自动恢复', 'Wi-Fi / 蜂窝切换时迁移出站连接', this.localNetworkRecover, (value: boolean) => {
          this.localNetworkRecover = value;
          this.save();
        })
        this.switchRow('锁屏保持', '锁屏后保留现有 VPN 会话', this.localScreenKeep, (value: boolean) => {
          this.localScreenKeep = value;
          this.save();
        })
        this.switchRow('断线阻断', '异常断开时阻止未保护流量直连', this.localFailClosed, (value: boolean) => {
          this.localFailClosed = value;
          this.save();
        })
        this.switchRow('连接状态通知', '显示当前节点和恢复记录', this.localNotificationOn, (value: boolean) => {
          this.localNotificationOn = value;
          this.save();
        })
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
  private coreGroup() {
    Column({ space: 0 }) {
      Text('核心与协议')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.sub'))
        .width('100%')
        .margin({ bottom: 8 })
      Column({ space: 0 }) {
        Row() {
          Column({ space: 3 }) {
            Text('代理核心')
              .fontSize(12)
              .fontColor($r('app.color.text'))
            Text('sing-box / libbox 内嵌')
              .fontSize(10)
              .fontColor($r('app.color.muted'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text('native')
            .fontSize(11)
            .fontColor($r('app.color.blue'))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(999)
            .backgroundColor($r('app.color.blue_soft'))
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .border({ width: 1, color: $r('app.color.line_soft') })

        Row() {
          Column({ space: 3 }) {
            Text('日志级别')
              .fontSize(12)
              .fontColor($r('app.color.text'))
            Text('写入本地诊断文件')
              .fontSize(10)
              .fontColor($r('app.color.muted'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text(this.localLogLevel)
            .fontSize(12)
            .fontColor($r('app.color.sub'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(8)
            .backgroundColor($r('app.color.surface2'))
            .border({ width: 1, color: $r('app.color.line') })
            .onClick(() => {
              this.localLogLevel = this.localLogLevel === 'info' ? 'debug' : 'info';
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .border({ width: 1, color: $r('app.color.line_soft') })
      }
      .width('100%')
      .borderRadius(8)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.line_soft') })
      .clip(true)

      Text('延迟测试地址')
        .fontSize(11)
        .fontColor($r('app.color.sub'))
        .width('100%')
        .margin({ top: 12, bottom: 6 })
      TextInput({ placeholder: 'https://www.gstatic.com/generate_204', text: this.localTestUrl })
        .height(40)
        .fontSize(12)
        .fontColor($r('app.color.text'))
        .placeholderColor($r('app.color.muted'))
        .backgroundColor($r('app.color.surface'))
        .border({ width: 1, color: $r('app.color.line_soft') })
        .borderRadius(8)
        .onChange((value: string) => {
          this.localTestUrl = value;
          // 立即落盘：本页其余开关都在 onChange 里 save()，唯独这个输入框
          // 原先只改本地状态，导致「改了测试地址却不生效」。
          this.save();
        })
      Button('测试连通性')
        .type(ButtonType.Normal)
        .fontSize(12)
        .fontColor($r('app.color.green'))
        .backgroundColor($r('app.color.green_soft'))
        .borderRadius(8)
        .height(38)
        .width('100%')
        .margin({ top: 10 })
        .onClick(this.onTestConnection)
    }
    .width('100%')
  }

  private subscriptionSummary(): string {
    if (this.subscriptions.length === 0) {
      return '未导入订阅';
    }
    for (let i = 0; i < this.subscriptions.length; i++) {
      if (this.subscriptions[i].active) {
        return this.subscriptions[i].name + ' · ' + this.subscriptions[i].nodeCount + ' 节点';
      }
    }
    return this.subscriptions.length + ' 个订阅（无激活项）';
  }

  @Builder
  private dataGroup() {
    Column({ space: 8 }) {
      Text('数据与订阅')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.sub'))
        .width('100%')
        .margin({ bottom: 8 })
      Column({ space: 0 }) {
        SettingActionRow({
          title: '订阅',
          desc: this.subscriptionSummary(),
          actionLabel: this.showSubManager ? '收起' : '管理',
          onAction: () => {
            this.showSubManager = !this.showSubManager;
          }
        })
        SettingActionRow({
          title: '配置文件',
          desc: this.configSummary.length > 0 ? this.configSummary : '尚未生成',
          actionLabel: this.showConfigDetail ? '收起' : '查看',
          onAction: () => {
            this.showConfigDetail = !this.showConfigDetail;
          }
        })
        SettingActionRow({
          title: '诊断记录',
          desc: this.diagnosticCount > 0 ? '本地最近事件 ' + this.diagnosticCount + ' 条' : '暂无记录',
          actionLabel: '清空',
          onAction: () => {
            this.onClearDiagnostics();
          }
        })
      }
      .width('100%')
      .borderRadius(8)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.line_soft') })
      .clip(true)

      if (this.statusMessage.length > 0) {
        Text(this.statusMessage)
          .fontSize(11)
          .fontColor($r('app.color.green'))
          .width('100%')
          .padding(10)
          .borderRadius(8)
          .backgroundColor($r('app.color.green_soft'))
      }

      if (this.showConfigDetail) {
        Column({ space: 6 }) {
          Text('当前生效配置')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.sub'))
            .width('100%')
          Text('大小 / 生成时间 / 规则数：' + (this.configSummary.length > 0 ? this.configSummary : '尚未生成'))
            .fontSize(11)
            .fontColor($r('app.color.text'))
            .width('100%')
          Text('配置由当前订阅在连接时生成；更换订阅或修改模式后重新连接即可生效。')
            .fontSize(10)
            .fontColor($r('app.color.muted'))
            .width('100%')
        }
        .width('100%')
        .padding(12)
        .borderRadius(8)
        .backgroundColor($r('app.color.surface'))
        .border({ width: 1, color: $r('app.color.line_soft') })
      }

      if (this.showSubManager) {
        this.subscriptionManager()
      }
    }
    .width('100%')
  }

  @Builder
  private subscriptionManager() {
    Column({ space: 8 }) {
      Row() {
        Text('订阅管理')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.sub'))
        Blank()
        Button('新增订阅')
          .type(ButtonType.Normal)
          .fontSize(11)
          .fontColor($r('app.color.green'))
          .backgroundColor($r('app.color.green_soft'))
          .borderRadius(6)
          .height(30)
          .onClick(this.onGotoNodes)
      }
      .width('100%')

      if (this.subscriptions.length === 0) {
        Text('暂无订阅 · 点击「新增订阅」去导入')
          .fontSize(11)
          .fontColor($r('app.color.muted'))
          .width('100%')
          .padding(12)
          .borderRadius(8)
          .backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.line_soft') })
      } else {
        ForEach(this.subscriptions, (item: SubscriptionProfile) => {
          SubManageRow({
            subId: item.id,
            name: item.name,
            format: item.detectedFormat,
            nodeCount: item.nodeCount,
            updatedAt: item.updatedAt,
            active: item.active,
            onRefresh: this.onRefreshSubscription,
            onDelete: this.onDeleteSubscription,
            onSelect: this.onSelectSubscription
          })
        }, (item: SubscriptionProfile) => item.id + '-' + item.updatedAt + '-' + item.active + '-' + item.nodeCount)
      }
    }
    .width('100%')
  }

  @Builder
  private infoRow(title: string, desc: string) {
    Row() {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(12)
          .fontColor($r('app.color.text'))
        Text(desc)
          .fontSize(10)
          .fontColor($r('app.color.muted'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button('管理')
        .type(ButtonType.Normal)
        .fontSize(12)
        .fontColor($r('app.color.blue'))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  @Builder
  private aboutGroup() {
    Column({ space: 0 }) {
      Text('关于')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.sub'))
        .width('100%')
        .margin({ bottom: 8 })
      Column({ space: 0 }) {
        this.infoRow('版本', 'LIAN CONNECT v0.02 测试版')
        this.infoRow('目标系统', 'HarmonyOS API 22+')
      }
      .width('100%')
      .borderRadius(8)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.line_soft') })
      .clip(true)
    }
    .width('100%')
    .margin({ top: 8 })
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

  private buildSettings(): AppSettings {
    return {
      autoConnect: this.localAutoConnect,
      networkRecover: this.localNetworkRecover,
      screenKeep: this.localScreenKeep,
      failClosed: this.localFailClosed,
      notificationOn: this.localNotificationOn,
      dnsMode: this.dnsMode,
      proxyMode: this.proxyMode,
      logLevel: this.localLogLevel,
      testUrl: this.localTestUrl,
      perAppProxyEnabled: this.perAppProxyEnabled
    };
  }

  private save(): void {
    this.onSave(this.buildSettings());
  }
}
