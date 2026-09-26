/**
 * 展示层格式化工具：把核心返回的原始字节/时间戳转成界面文案。
 * 所有数值均来自真实统计，不做任何模拟。
 */
export class Fmt {
  static bytes(n: number): string {
    if (n <= 0) {
      return '0 B';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value = n;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value = value / 1024;
      unit++;
    }
    const text = unit === 0 ? value.toFixed(0) : value.toFixed(2);
    return text + ' ' + units[unit];
  }

  static speed(n: number): string {
    return Fmt.bytes(n) + '/s';
  }

  /** 连接时长：毫秒 -> "18 分钟" */
  static duration(ms: number): string {
    if (ms <= 0) {
      return '—';
    }
    const totalSeconds = Math.floor(ms / 1000);
    if (totalSeconds < 60) {
      return totalSeconds + ' 秒';
    }
    const minutes = Math.floor(totalSeconds / 60);
    if (minutes < 60) {
      return minutes + ' 分钟';
    }
    const hours = Math.floor(minutes / 60);
    return hours + ' 小时 ' + (minutes % 60) + ' 分钟';
  }

  /** 距今时间：时间戳 -> "4 分钟前" */
  static ago(ts: number): string {
    if (ts <= 0) {
      return '未测速';
    }
    const diff = Date.now() - ts;
    if (diff < 5000) {
      return '刚刚';
    }
    if (diff < 60000) {
      return Math.floor(diff / 1000) + ' 秒前';
    }
    if (diff < 3600000) {
      return Math.floor(diff / 60000) + ' 分钟前';
    }
    return Math.floor(diff / 3600000) + ' 小时前';
  }

  /** 时间戳 -> "10:31:22" */
  static clock(ts: number): string {
    const d = new Date(ts);
    const hh = d.getHours() < 10 ? '0' + d.getHours() : '' + d.getHours();
    const mm = d.getMinutes() < 10 ? '0' + d.getMinutes() : '' + d.getMinutes();
    const ss = d.getSeconds() < 10 ? '0' + d.getSeconds() : '' + d.getSeconds();
    return hh + ':' + mm + ':' + ss;
  }

  /** 延迟展示 */
  static latency(ms: number): string {
    return ms > 0 ? ms + ' ms' : '未测';
  }
}
