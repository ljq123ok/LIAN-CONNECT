import { common } from '@kit.AbilityKit';
import fileIo from '@ohos.file.fs';

/**
 * 核心运行时状态（由 VPN 扩展进程每秒写入 core-status.json）。
 * 字段与 core/bridge.go 的 statusPayload 一一对应。
 */
export interface CoreStatus {
  running: boolean;
  version: string;
  fd: number;
  configPath: string;
  error: string;
  /** 以下上下行均为“仅代理流量”（不含 DIRECT 直连） */
  up: number;
  down: number;
  upTotal: number;
  downTotal: number;
  connections: number;
  proxyConnections: number;
  memory: number;
  /** 当前出站模式：rule / global / direct */
  mode: string;
  /** 链路健康：ok / fail / unknown（真实出口 URL 探测结果） */
  healthState: string;
  healthDelay: number;
  healthCheckedAt: number;
  healthyNodes: number;
  totalNodes: number;
  currentNode: string;
  /** 链路自愈次数 */
  recoverCount: number;
  startedAt: number;
  /** 心跳时间戳（毫秒）：用于判断状态新鲜度与真实连接状态 */
  ts: number;
  /** 由读取方填充：状态文件距今多久（毫秒）。旧格式无 ts 字段时用它判断新鲜度 */
  fileAgeMs: number;
}

/** 单条活跃连接（与 core/bridge.go 的 connPayload 对应） */
export interface CoreConnection {
  id: string;
  host: string;
  destination: string;
  network: string;
  rule: string;
  rulePayload: string;
  chains: string[];
  up: number;
  down: number;
  startMs: number;
  proxied: boolean;
}

export interface ConnectionsSnapshot {
  list: CoreConnection[];
  ageMs: number;
}

/**
 * 读取 mihomo 核心的真实运行状态、流量统计与连接明细。
 * UIAbility 与 VpnExtensionAbility 同属 entry 模块沙箱，共享 filesDir，
 * 因此主进程可以直接读取扩展进程写出的状态文件。
 */
export class CoreStatusStore {
  private statusPath: string;
  private connectionsPath: string;
  private commandPath: string;

  constructor(context: common.UIAbilityContext) {
    const dir = context.filesDir + '/lian-core';
    this.statusPath = dir + '/core-status.json';
    this.connectionsPath = dir + '/core-connections.json';
    this.commandPath = dir + '/core-command.json';
  }

  read(): CoreStatus | undefined {
    const parsed = this.readJson<CoreStatus>(this.statusPath);
    return parsed;
  }

  /** 活跃连接明细（由扩展每秒写出） */
  readConnections(): ConnectionsSnapshot | undefined {
    const raw = this.readText(this.connectionsPath);
    if (raw === undefined) {
      return undefined;
    }
    try {
      const list = JSON.parse(raw) as CoreConnection[];
      if (list === null || list === undefined) {
        return undefined;
      }
      return { list: list, ageMs: this.ageOf(this.connectionsPath) };
    } catch (_err) {
      return undefined;
    }
  }


  /**
   * 请求核心把手动选择的节点应用到指定策略组。
   *
   * 为什么必须走这条路：界面上的「选择节点」此前只改 JS 侧变量，
   * 从未通知核心，于是出现「选了日本节点、实际出口却是组内自动测速
   * 选出的其它地区」。核心侧新增了 selectNode 命令来接收该选择。
   *
   * @param name 节点名（必须是该组成员，否则核心会忽略并记录日志）
   * @param group 策略组名；留空表示主组（成员最多的那个）
   * @returns 是否成功写入命令
   */
  requestSelectNode(name: string, group: string = ''): boolean {
    if (name.length === 0) {
      return false;
    }
    const cmd: ModeCommand = {
      seq: Date.now(),
      selectNode: name,
      selectGroup: group
    };
    return this.writeCommand(cmd);
  }
  /**
   * 请求核心热切换出站模式（通过命令文件，扩展每秒轮询并应用）。
   * @returns 是否成功写入命令
   */
  requestMode(mode: string): boolean {
    const cmd: ModeCommand = { seq: Date.now(), mode: mode };
    return this.writeCommand(cmd);
  }

  /** 关闭单条连接 */
  requestCloseConnection(id: string): boolean {
    const cmd: ModeCommand = { seq: Date.now(), closeId: id };
    return this.writeCommand(cmd);
  }

  /** 关闭全部连接 */
  requestCloseAll(): boolean {
    const cmd: ModeCommand = { seq: Date.now(), closeAll: true };
    return this.writeCommand(cmd);
  }

  private writeCommand(cmd: ModeCommand): boolean {
    try {
      const tmp = this.commandPath + '.tmp';
      let fd = -1;
      const file = fileIo.openSync(tmp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fd = file.fd;
      try {
        fileIo.writeSync(fd, JSON.stringify(cmd));
      } finally {
        if (fd >= 0) {
          fileIo.closeSync(fd);
        }
      }
      fileIo.renameSync(tmp, this.commandPath);
      return true;
    } catch (_err) {
      return false;
    }
  }

  private readJson<T>(path: string): T | undefined {
    const raw = this.readText(path);
    if (raw === undefined) {
      return undefined;
    }
    try {
      const parsed = JSON.parse(raw) as T;
      if (parsed === null || parsed === undefined) {
        return undefined;
      }
      if (path === this.statusPath) {
        const status = parsed as object as CoreStatus;
        status.fileAgeMs = this.ageOf(path);
      }
      return parsed;
    } catch (_err) {
      return undefined;
    }
  }

  private readText(path: string): string | undefined {
    try {
      const raw = fileIo.readTextSync(path);
      return raw.length > 0 ? raw : undefined;
    } catch (_err) {
      return undefined;
    }
  }

  /** 文件距今毫秒数 */
  private ageOf(path: string): number {
    try {
      const stat = fileIo.statSync(path);
      // mtime 通常为秒；兼容返回毫秒的实现
      const mtimeMs: number = stat.mtime > 100000000000 ? stat.mtime : stat.mtime * 1000;
      return Date.now() - mtimeMs;
    } catch (_err) {
      return Number.MAX_SAFE_INTEGER;
    }
  }
}

/** 写入 core-command.json 的核心指令（模式切换 / 关闭连接） */
export interface ModeCommand {
  seq: number;
  mode?: string;
  closeId?: string;
  closeAll?: boolean;
  /** 手动指定的策略组名；为空表示主组 */
  selectGroup?: string;
  /** 手动指定的节点名 */
  selectNode?: string;
}
