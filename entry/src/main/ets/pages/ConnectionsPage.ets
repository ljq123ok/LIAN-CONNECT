import { ContentFrame } from '../common/ContentFrame';
import { Fmt } from '../common/Format';
import { CoreConnection } from '../services/CoreStatusStore';

@Component
export struct ConnectionsPage {
  @Prop connected: boolean = false;
  /** 真实活跃连接（来自 mihomo 核心，每秒刷新） */
  @Prop coreConnections: CoreConnection[] = [];
  onClose: (id: string) => void = () => {
  };
  onCloseAll: () => void = () => {
  };
  @State private searchText: string = '';

  build() {
    Scroll() {
      ContentFrame() {
      Column({ space: 12 }) {
        this.summary()
        Row({ space: 8 }) {
          TextInput({ placeholder: '搜索域名、规则或出口', text: this.searchText })
            .height(40)
            .fontSize(13)
            .fontColor($r('app.color.text'))
            .placeholderColor($r('app.color.muted'))
            .backgroundColor($r('app.color.surface'))
            .border({ width: 1, color: $r('app.color.line_soft') })
            .borderRadius(8)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.searchText = value;
            })
          Button('全部关闭')
            .type(ButtonType.Normal)
            .fontSize(12)
            .fontColor($r('app.color.red'))
            .backgroundColor($r('app.color.red_soft'))
            .borderRadius(8)
            .height(40)
            .onClick(this.onCloseAll)
        }
        .width('100%')
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

  /** 汇总：连接数按“全部/走代理”拆分，流量为核心真实累计值 */
  @Builder
  private summary() {
    Row({ space: 8 }) {
      this.summaryCell('活跃连接', this.connected ? '' + this.coreConnections.length : '—')
      this.summaryCell('其中走代理', this.connected ? '' + this.proxiedCount() : '—')
      this.summaryCell('代理总流量', this.connected ? Fmt.bytes(this.totalBytes()) : '—')
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

  private proxiedCount(): number {
    let count = 0;
    for (let i = 0; i < this.coreConnections.length; i++) {
      if (this.coreConnections[i].proxied) {
        count++;
      }
    }
    return count;
  }

  private totalBytes(): number {
    let sum = 0;
    for (let i = 0; i < this.coreConnections.length; i++) {
      sum += this.coreConnections[i].up + this.coreConnections[i].down;
    }
    return sum;
  }

  @Builder
  private list() {
    if (!this.connected) {
      Text('连接 VPN 后查看实时连接')
        .fontSize(12)
        .fontColor($r('app.color.muted'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding(40)
        .borderRadius(8)
        .backgroundColor($r('app.color.surface'))
        .border({ width: 1, color: $r('app.color.line_soft') })
    } else {
      if (this.filteredConnections().length === 0) {
        Text('当前没有匹配的连接')
          .fontSize(12)
          .fontColor($r('app.color.muted'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding(40)
          .borderRadius(8)
          .backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.line_soft') })
      } else {
        ForEach(this.filteredConnections(), (conn: CoreConnection) => {
          this.connRow(conn)
        }, (conn: CoreConnection) => conn.id + '-' + conn.up + '-' + conn.down)
      }
    }
  }

  private filteredConnections(): CoreConnection[] {
    const keyword = this.searchText.trim().toLowerCase();
    return this.coreConnections.filter((conn: CoreConnection) =>
      keyword.length === 0 ||
      conn.host.toLowerCase().indexOf(keyword) >= 0 ||
      conn.destination.toLowerCase().indexOf(keyword) >= 0 ||
      conn.rule.toLowerCase().indexOf(keyword) >= 0);
  }

  private displayHost(conn: CoreConnection): string {
    if (conn.host.length > 0) {
      return conn.host;
    }
    return conn.destination.length > 0 ? conn.destination : '(未知目标)';
  }

  private egressLabel(conn: CoreConnection): string {
    if (!conn.proxied) {
      return '直连';
    }
    if (conn.chains.length > 0) {
      return conn.chains[conn.chains.length - 1];
    }
    return '代理';
  }

  @Builder
  private connRow(conn: CoreConnection) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(this.displayHost(conn))
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .maxLines(1)
        Row({ space: 10 }) {
          Text(conn.network.toUpperCase())
            .fontSize(10)
            .fontColor(conn.proxied ? $r('app.color.green') : $r('app.color.muted'))
          Text('规则 ' + (conn.rule.length > 0 ? conn.rule : '-'))
            .fontSize(10)
            .fontColor($r('app.color.muted'))
            .maxLines(1)
          Text('出口 ' + this.egressLabel(conn))
            .fontSize(10)
            .fontColor($r('app.color.muted'))
            .maxLines(1)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column({ space: 6 }) {
        Text('↓ ' + Fmt.bytes(conn.down))
          .fontSize(11)
          .fontColor($r('app.color.sub'))
        Text('↑ ' + Fmt.bytes(conn.up))
          .fontSize(11)
          .fontColor($r('app.color.sub'))
        Button('X')
          .type(ButtonType.Normal)
          .fontSize(11)
          .fontColor($r('app.color.muted'))
          .backgroundColor($r('app.color.surface2'))
          .border({ width: 1, color: $r('app.color.line') })
          .borderRadius(8)
          .height(26)
          .width(28)
          .onClick(() => {
            this.onClose(conn.id);
          })
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }
}
