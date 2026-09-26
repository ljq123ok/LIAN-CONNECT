/**
 * ContentFrame —— 宽屏内容限宽容器（方案 A）
 *
 * 将子内容限制在 maxWidth(560)vp 内并水平居中：
 * - 大屏手机（约 440vp）/ 常规手机（360~430vp）：宽度 < 560vp，不触发；
 * - 折叠屏展开 / 平板(> 560vp)：内容收窄到 560vp 居中，卡片不再被无限拉宽。
 * 用法：Scroll() { ContentFrame() { 原内容(Column 等) } }，Scroll 自身仍铺满全屏。
 */
@Component
export struct ContentFrame {
  @BuilderParam content: () => void;

  build() {
    Row() {
      Column() {
        this.content()
      }
      .width('100%')
      .constraintSize({ maxWidth: 560 })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }
}
