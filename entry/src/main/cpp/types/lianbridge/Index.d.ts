export const start: (fd: number, configPath: string, homeDir: string) => string;
export const status: () => string;
export const version: () => string;
export const stop: () => void;
/** 当前活跃连接明细（JSON 字符串） */
export const connections: () => string;
/** 热切换出站模式：rule / global / direct */
export const setMode: (mode: string) => string;
/** 关闭连接：传 id 关闭单条，传空字符串关闭全部 */
export const closeConnection: (id: string) => string;
/** 真实链路健康探测（对当前出口做 URL 测试），返回 JSON */
export const health: () => string;
/**
 * 手动指定出口节点（组名留空表示主组），返回 JSON 状态。
 *
 * 存在的意义：url-test 组不尊重手动选择（它每次拨号都重新测速选点），
 * 因此配置里生成了 select 类型的「手动选择」组来承载用户的指定。
 */
export const selectNode: (group: string, name: string) => string;
