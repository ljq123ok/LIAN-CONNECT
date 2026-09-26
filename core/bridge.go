package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	cconstant "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// ===== 仅统计“走代理”的流量 =====
// mihomo 的全局统计包含 DIRECT（国内直连）流量，这里按连接的代理链过滤，
// 只累计真正经过代理节点的字节数。

type connSample struct {
	up      int64
	down    int64
	proxied bool
}

type trafficAccumulator struct {
	mu        sync.Mutex
	seen      map[string]connSample
	upTotal   int64
	downTotal int64
	upSpeed   int64
	downSpeed int64
	lastTick  time.Time
}

var proxyTraffic = trafficAccumulator{seen: make(map[string]connSample)}

// isProxiedChain 判断代理链是否走了代理（首跳非 DIRECT 即视为代理）
func isProxiedChain(chain []string) bool {
	if len(chain) == 0 {
		return false
	}
	return !strings.EqualFold(chain[0], "DIRECT")
}

// update 采样活跃连接，累计“代理流量”并算出每秒速率
func (a *trafficAccumulator) update(snapshot *statistic.Snapshot) (total int, proxied int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	fresh := make(map[string]connSample, len(snapshot.Connections))
	var dUp, dDown int64
	for _, c := range snapshot.Connections {
		if c == nil {
			continue
		}
		id := c.UUID.String()
		up := c.UploadTotal.Load()
		down := c.DownloadTotal.Load()
		viaProxy := isProxiedChain(c.Chain)
		fresh[id] = connSample{up: up, down: down, proxied: viaProxy}
		if viaProxy {
			proxied++
		}
		prev, ok := a.seen[id]
		if !ok {
			// 新出现的连接：把它当前已传字节全部计入（该连接自建立以来的量）
			if viaProxy {
				dUp += up
				dDown += down
			}
			continue
		}
		if viaProxy {
			if up > prev.up {
				dUp += up - prev.up
			}
			if down > prev.down {
				dDown += down - prev.down
			}
		}
	}
	a.upTotal += dUp
	a.downTotal += dDown
	if !a.lastTick.IsZero() {
		elapsed := now.Sub(a.lastTick).Seconds()
		if elapsed > 0 {
			a.upSpeed = int64(float64(dUp) / elapsed)
			a.downSpeed = int64(float64(dDown) / elapsed)
		}
	}
	a.lastTick = now
	a.seen = fresh
	return len(snapshot.Connections), proxied
}

type bridgeState struct {
	mu         sync.Mutex
	running    bool
	fd         int
	configPath string
	lastError  string
}

var state = bridgeState{}

type statusPayload struct {
	Running    bool   `json:"running"`
	Version    string `json:"version"`
	Fd         int    `json:"fd"`
	ConfigPath string `json:"configPath"`
	Error      string `json:"error,omitempty"`
	// 以下上下行字段仅统计“经代理”的流量（不含 DIRECT 直连）
	Up          int64 `json:"up"`
	Down        int64 `json:"down"`
	UpTotal     int64 `json:"upTotal"`
	DownTotal   int64 `json:"downTotal"`
	Connections int   `json:"connections"`
	// 其中走代理的连接数
	ProxyConnections int    `json:"proxyConnections"`
	Memory           int64  `json:"memory"`
	Mode             string `json:"mode"`
	// 链路健康：核心存活 != 隧道可用，UI 必须据真实出口探测判定
	HealthState     string `json:"healthState"`
	HealthDelay     int    `json:"healthDelay"`
	HealthCheckedAt int64  `json:"healthCheckedAt"`
	HealthyNodes    int    `json:"healthyNodes"`
	TotalNodes      int    `json:"totalNodes"`
	CurrentNode     string `json:"currentNode"`
}

func bridgeStatus() statusPayload {
	state.mu.Lock()
	defer state.mu.Unlock()
	return bridgeStatusLocked()
}

// bridgeStatusLocked returns a snapshot when the caller already holds state.mu.
// Calling bridgeStatus from LianCoreStart would try to lock the non-reentrant
// mutex twice and permanently block the VPN extension's main thread.
func bridgeStatusLocked() statusPayload {
	// 统计只在核心运行时读取，避免停止后读到陈旧数据
	var conns, proxyConns int
	var mem int64
	if state.running {
		snapshot := statistic.DefaultManager.Snapshot()
		if snapshot != nil {
			conns, proxyConns = proxyTraffic.update(snapshot)
			mem = int64(snapshot.Memory)
		}
	}
	hp := collectHealth()
	proxyTraffic.mu.Lock()
	up := proxyTraffic.upSpeed
	down := proxyTraffic.downSpeed
	upTotal := proxyTraffic.upTotal
	downTotal := proxyTraffic.downTotal
	proxyTraffic.mu.Unlock()
	return statusPayload{
		Running:          state.running,
		Version:          cconstant.Version,
		Fd:               state.fd,
		ConfigPath:       state.configPath,
		Error:            state.lastError,
		Up:               up,
		Down:             down,
		UpTotal:          upTotal,
		DownTotal:        downTotal,
		Connections:      conns,
		ProxyConnections: proxyConns,
		Memory:           mem,
		Mode:             strings.ToLower(tunnel.Mode().String()),
		HealthState:      hp.State,
		HealthDelay:      hp.Delay,
		HealthCheckedAt:  hp.CheckedAt,
		HealthyNodes:     hp.HealthyNodes,
		TotalNodes:       hp.TotalNodes,
		CurrentNode:      hp.CurrentNode,
	}
}

func cstr(s string) *C.char {
	return C.CString(s)
}

func applyStopConfig() error {
	raw := config.DefaultRawConfig()
	raw.Port = 0
	raw.SocksPort = 0
	raw.RedirPort = 0
	raw.TProxyPort = 0
	raw.MixedPort = 0
	raw.Tun.Enable = false
	raw.Tun.FileDescriptor = 0
	raw.ExternalController = ""
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		return err
	}
	executor.ApplyConfig(cfg, true)
	route.ReCreateServer(&route.Config{})
	listener.ReCreateTun(LC.Tun{Enable: false}, tunnel.Tunnel)
	return nil
}

//export LianCoreVersion
func LianCoreVersion() *C.char {
	return cstr(cconstant.Version)
}

//export LianCoreStatus
func LianCoreStatus() *C.char {
	payload, _ := json.Marshal(bridgeStatus())
	return cstr(string(payload))
}

// connPayload 单个连接的脱敏明细（供“实时连接”页面展示真实连接）
type connPayload struct {
	ID          string   `json:"id"`
	Host        string   `json:"host"`
	Destination string   `json:"destination"`
	Network     string   `json:"network"`
	Rule        string   `json:"rule"`
	RulePayload string   `json:"rulePayload"`
	Chains      []string `json:"chains"`
	Up          int64    `json:"up"`
	Down        int64    `json:"down"`
	StartMs     int64    `json:"startMs"`
	Proxied     bool     `json:"proxied"`
}

//export LianCoreConnections
func LianCoreConnections() *C.char {
	state.mu.Lock()
	running := state.running
	state.mu.Unlock()

	list := make([]connPayload, 0, 64)
	if running {
		snapshot := statistic.DefaultManager.Snapshot()
		if snapshot != nil {
			for _, c := range snapshot.Connections {
				if c == nil {
					continue
				}
				host := ""
				dest := ""
				network := "tcp"
				if c.Metadata != nil {
					host = c.Metadata.Host
					if c.Metadata.DstIP.IsValid() {
						dest = c.Metadata.DstIP.String()
						if c.Metadata.DstPort > 0 {
							dest = dest + ":" + fmt.Sprintf("%d", c.Metadata.DstPort)
						}
					}
					if c.Metadata.Type.String() != "" {
						network = strings.ToLower(c.Metadata.Type.String())
					}
				}
				chains := make([]string, 0, len(c.Chain))
				for _, ch := range c.Chain {
					chains = append(chains, ch)
				}
				list = append(list, connPayload{
					ID:          c.UUID.String(),
					Host:        host,
					Destination: dest,
					Network:     network,
					Rule:        c.Rule,
					RulePayload: c.RulePayload,
					Chains:      chains,
					Up:          c.UploadTotal.Load(),
					Down:        c.DownloadTotal.Load(),
					StartMs:     c.Start.UnixMilli(),
					Proxied:     isProxiedChain(c.Chain),
				})
			}
		}
	}
	// 按流量从大到小，最多返回 100 条，避免状态文件过大
	sort.Slice(list, func(i, j int) bool {
		return (list[i].Up + list[i].Down) > (list[j].Up + list[j].Down)
	})
	if len(list) > 100 {
		list = list[:100]
	}
	payload, _ := json.Marshal(list)
	return cstr(string(payload))
}

//export LianCoreSetMode
// builtinGroupNames 是 mihomo 内置、不参与本应用分流决策的组名。
// GLOBAL 恒存在且包含全部节点，因此成员数常常最大，必须排除，
// 否则会被误当成「主组」而把选择应用到它上面。
var builtinGroupNames = map[string]bool{
	"GLOBAL":     true,
	"DIRECT":     true,
	"REJECT":     true,
	"REJECT-DROP": true,
	"PASS":       true,
	"COMPATIBLE": true,
}

// largestRoutingGroup 返回成员最多的**非内置**组。
// 本应用生成的配置里即「手动选择」组（规则 MATCH 指向它）。
func largestRoutingGroup() cconstant.Proxy {
	var best cconstant.Proxy
	bestCount := -1
	for name, p := range tunnel.Proxies() {
		if builtinGroupNames[name] {
			continue
		}
		gm, ok := groupOf(p)
		if !ok {
			continue
		}
		if c := len(gm.Proxies()); c > bestCount {
			best = p
			bestCount = c
		}
	}
	return best
}

//export LianCoreSelectNode
// LianCoreSelectNode 把手动选择的节点下发给核心。
//
// 背景：界面上的「选择节点」原先只改 JS 侧变量，从未通知核心，
// 导致用户选了日本节点、实际出口仍是组内自动测速选出的其它地区
// （实测出现过卡塔尔节点）。这里补齐这条通道。
//
// groupName 为空时对主组（成员最多的组）生效，覆盖本应用默认只生成
// 单一「自动选择」组的情况；name 必须是该组的成员节点名，否则返回错误。
func LianCoreSelectNode(groupNameC, nameC *C.char) *C.char {
	groupName := strings.TrimSpace(C.GoString(groupNameC))
	name := strings.TrimSpace(C.GoString(nameC))
	if name == "" {
		payload, _ := json.Marshal(bridgeStatus())
		return cstr(string(payload))
	}

	var target cconstant.Proxy
	if groupName != "" {
		for n, p := range tunnel.Proxies() {
			if n == groupName {
				target = p
				break
			}
		}
	}
	if target == nil {
		// 回退：取最大的「非内置」业务组。
		//
		// 这里**不能**用 mainGroup()：它取成员最多的组，而 mihomo 内置的
		// GLOBAL 通常比业务组还大（实测 GLOBAL=323 > 手动选择=319），
		// 于是选择被应用到 GLOBAL，而规则真正指向的分流组纹丝不动 ——
		// 表现为「日志说切换成功，但出口地区没变」。
		target = largestRoutingGroup()
	}
	if target == nil {
		log.Warnln("select node %q: group %q not found", name, groupName)
		payload, _ := json.Marshal(bridgeStatus())
		return cstr(string(payload))
	}

	// 必须先 Adapter() 解包：tunnel.Proxies() 返回的是 *adapter.Proxy 包装层，
	// 真正的组实现（Selector/URLTest）在其内部。直接对包装层做类型断言会
	// 永远失败，导致 Set() 从未被调用 —— 表现为「日志说切换成功、
	// 出口却毫无变化」。mihomo 官方 HTTP API 就是这么解包的
	// （hub/route/proxies.go:85 `proxy.Adapter().(outboundgroup.SelectAble)`）。
	sel, ok := target.Adapter().(outboundgroup.SelectAble)
	if !ok {
		log.Warnln("select node %q: group %q is not selectable", name, groupName)
		payload, _ := json.Marshal(bridgeStatus())
		return cstr(string(payload))
	}
	if err := sel.Set(name); err != nil {
		// 节点名不存在（例如订阅更新后改名）时不改变现状，仅记录。
		log.Warnln("select node %q in group %q failed: %v", name, groupName, err)
	}
	payload, _ := json.Marshal(bridgeStatus())
	return cstr(string(payload))
}

func LianCoreSetMode(modeC *C.char) *C.char {
	name := strings.ToLower(strings.TrimSpace(C.GoString(modeC)))
	m, ok := tunnel.ModeMapping[name]
	if !ok {
		m = tunnel.Rule
	}
	tunnel.SetMode(m)
	payload, _ := json.Marshal(bridgeStatus())
	return cstr(string(payload))
}

type closeResult struct {
	Closed int `json:"closed"`
}

//export LianCoreCloseConnection
// CloseConnection closes one connection by id, or every tracked connection
// when the id is empty (used by the "close all" action).
func LianCoreCloseConnection(idC *C.char) *C.char {
	id := C.GoString(idC)
	state.mu.Lock()
	running := state.running
	state.mu.Unlock()

	closed := 0
	if running {
		if id == "" {
			statistic.DefaultManager.Range(func(t statistic.Tracker) bool {
				if err := t.Close(); err == nil {
					closed++
				}
				return true
			})
		} else {
			statistic.DefaultManager.Range(func(t statistic.Tracker) bool {
				if t.ID() == id {
					if err := t.Close(); err == nil {
						closed++
					}
					return false
				}
				return true
			})
		}
	}
	payload, _ := json.Marshal(closeResult{Closed: closed})
	return cstr(string(payload))
}

// ===== 链路健康探测 =====
// 只判断核心进程存活是不够的：节点会失效、凭据会过期，
// 必须对真实出口做 URL 测试才能确认隧道是否可用。

type healthState struct {
	mu      sync.Mutex
	state   string // unknown / ok / fail
	delay   int
	checked int64
	detail  string
	// checking prevents overlapping network probes. generation invalidates a
	// probe that was started before the core was stopped or rebuilt.
	checking   bool
	generation uint64
	// failStreak 连续失败次数。单次探测失败不足以判定链路断开：
	// 复用连接被服务端正常回收（EOF / "server closed idle connection"）
	// 也会让 URLTest 返回错误，而此刻用户实际仍能正常上网。
	// 只有连续失败达到 healthFailThreshold 才对外暴露 fail。
	failStreak int
}

var coreHealth = healthState{state: "unknown"}

const healthTestUrl = "http://www.gstatic.com/generate_204"

// healthFailThreshold 连续失败多少次才判定链路异常。
// 取 2：单次抖动（探测间隔 30s）不报警；连续两次即约 1 分钟内确实不通。
const healthFailThreshold = 2

// groupMembers / groupNow 用最小接口分别断言，
// 避免因某个组未实现完整 outboundgroup.ProxyGroup 组合接口而断言失败。
type groupMembers interface {
	Proxies() []cconstant.Proxy
}

type groupNow interface {
	Now() string
}

func groupOf(p cconstant.Proxy) (groupMembers, bool) {
	if p == nil {
		return nil, false
	}
	if gm, ok := p.(groupMembers); ok {
		return gm, true
	}
	// tunnel.Proxies() 通常给出 *adapter.Proxy 包装层，组的
	// Proxies()/Now() 都在 Adapter() 返回的真实实现上。
	gm, ok := p.Adapter().(groupMembers)
	return gm, ok
}

// mainGroup 取真正承载分流规则的业务组。
//
// 不能在这里简单取“成员最多”：内置 GLOBAL 往往比“手动选择”
// 还多，但真实 rules/MATCH 并不指向 GLOBAL。健康探测若测错组，就会
// 把“实际出口已断”误报成正常。
func mainGroup() (cconstant.Proxy, bool) {
	if manual, ok := tunnel.Proxies()["手动选择"]; ok && manual != nil {
		return manual, true
	}
	best := largestRoutingGroup()
	if best != nil {
		return best, true
	}
	return nil, false
}

// currentOutboundName 当前实际出口节点名（组的 Now()）
func currentOutboundName() string {
	if g, ok := mainGroup(); ok {
		// tunnel.Proxies() 返回 adapter.Proxy 包装层，Now() 在内部
		// Selector/URLTest 实现上；与 selectNode 一样必须先解包。
		if gn, ok2 := g.Adapter().(groupNow); ok2 {
			return gn.Now()
		}
	}
	return ""
}

// outboundOf 取探测目标：优先代理组（对其做 URL 测试即测真实代理链路）
func outboundOf() (string, cconstant.Proxy) {
	if g, ok := mainGroup(); ok {
		return currentOutboundName(), g
	}
	for name, p := range tunnel.Proxies() {
		if p != nil {
			return name, p
		}
	}
	return "", nil
}

// tunHealthy 报告 TUN 监听当前是否处于启用状态。
//
// 这是数据面的关键判据：config 应用成功、节点可拨通，都不代表设备流量
// 能进入隧道。TUN 一旦被 ReCreateTun(Enable:false) 关闭（自愈重建、
// stop 流程都会走到），核心仍在 running，但所有应用流量都会失去出口。
func tunHealthy() bool {
	return listener.GetTunConf().Enable
}

// runHealthCheck 对当前出口做一次真实 URL 测试。
//
// 注意它的**局限**：URLTest 由核心进程直接拨号到节点，**不经过 TUN**。
// 因此它只能证明「节点服务器可达」，不能证明「设备流量真的进了隧道」。
// 隧道本身是否还在承载流量，由 tunHealthy() 单独核对。
func runHealthCheck(timeout time.Duration, generation uint64) bool {
	// 先核对数据面：TUN 监听若已被销毁（例如扩展/核心重建过程中掉了），
	// 即使节点能拨通，设备流量也无处可去 —— 这正是「显示已连接但实际
	// 不可用」的形态。此处判定为 fail，交由上层触发自愈。
	if !tunHealthy() {
		coreHealth.mu.Lock()
		if coreHealth.generation != generation {
			coreHealth.mu.Unlock()
			return false
		}
		coreHealth.state = "fail"
		coreHealth.detail = "tun listener disabled"
		coreHealth.delay = 0
		coreHealth.checked = time.Now().UnixMilli()
		coreHealth.failStreak = healthFailThreshold
		coreHealth.mu.Unlock()
		return false
	}
	_, proxy := outboundOf()
	now := time.Now().UnixMilli()
	if proxy == nil {
		coreHealth.mu.Lock()
		if coreHealth.generation != generation {
			coreHealth.mu.Unlock()
			return false
		}
		coreHealth.state = "fail"
		coreHealth.detail = "no outbound"
		coreHealth.checked = now
		coreHealth.delay = 0
		coreHealth.mu.Unlock()
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	d, err := proxy.URLTest(ctx, healthTestUrl, nil)
	coreHealth.mu.Lock()
	defer coreHealth.mu.Unlock()
	if coreHealth.generation != generation {
		return false
	}
	coreHealth.checked = time.Now().UnixMilli()
	if err == nil && d > 0 {
		coreHealth.failStreak = 0
		coreHealth.state = "ok"
		coreHealth.delay = int(d)
		coreHealth.detail = ""
		return true
	}

	// 探测失败：先累计连续失败次数，不立刻对外报 fail。
	// 理由见 healthState.failStreak 的说明——单次 EOF 多为连接复用被回收，
	// 属于伪失败。立刻报 fail 会让界面在接下来约 30 秒（下一个探测周期）
	// 一直显示「链路异常」，而用户此时其实能正常上网。
	coreHealth.failStreak++
	if err != nil {
		coreHealth.detail = err.Error()
	} else {
		coreHealth.detail = "timeout"
	}
	if coreHealth.failStreak < healthFailThreshold {
		// 未达阈值：保持上一次的对外状态，仅更新 detail 供诊断观察。
		return false
	}

	coreHealth.state = "fail"
	coreHealth.delay = 0
	return false
}

// triggerHealthCheck starts at most one network probe and returns immediately.
// LianCoreHealth is called synchronously through N-API on the VPN extension's
// ArkTS main thread, so doing URLTest there would block that thread for up to
// five seconds and trigger HarmonyOS THREAD_BLOCK_3S process termination.
func triggerHealthCheck(timeout time.Duration) {
	coreHealth.mu.Lock()
	if coreHealth.checking {
		coreHealth.mu.Unlock()
		return
	}
	generation := coreHealth.generation
	coreHealth.checking = true
	coreHealth.mu.Unlock()

	go func() {
		runHealthCheck(timeout, generation)
		coreHealth.mu.Lock()
		if coreHealth.generation == generation {
			coreHealth.checking = false
		}
		coreHealth.mu.Unlock()
	}()
}

type healthPayload struct {
	State        string `json:"state"`
	Delay        int    `json:"delay"`
	CheckedAt    int64  `json:"checkedAt"`
	Detail       string `json:"detail,omitempty"`
	CurrentNode  string `json:"currentNode"`
	HealthyNodes int    `json:"healthyNodes"`
	TotalNodes   int    `json:"totalNodes"`
	// FailStreak 当前连续失败次数（未达阈值时 state 保持上一次的值）。
	// 供诊断区分「链路真的断了」与「单次探测抖动」。
	FailStreak int `json:"failStreak,omitempty"`
}

// collectHealth 汇总健康状态（不触发新的探测）
func collectHealth() healthPayload {
	coreHealth.mu.Lock()
	st := coreHealth.state
	delay := coreHealth.delay
	checked := coreHealth.checked
	detail := coreHealth.detail
	streak := coreHealth.failStreak
	coreHealth.mu.Unlock()

	_, proxy := outboundOf()
	healthy, total := countHealthy(proxy)
	return healthPayload{
		State:        st,
		Delay:        delay,
		CheckedAt:    checked,
		Detail:       detail,
		CurrentNode:  currentOutboundName(),
		HealthyNodes: healthy,
		TotalNodes:   total,
		FailStreak:   streak,
	}
}

// countHealthy 用已有测速历史统计组内可用节点（不发起新请求）
func countHealthy(proxy cconstant.Proxy) (int, int) {
	if proxy == nil {
		return 0, 0
	}
	gm, ok := groupOf(proxy)
	if !ok {
		return 1, 1
	}
	list := gm.Proxies()
	healthy := 0
	for _, p := range list {
		if p == nil {
			continue
		}
		if h := p.DelayHistory(); len(h) > 0 && p.AliveForTestUrl(healthTestUrl) {
			healthy++
		}
	}
	return healthy, len(list)
}

//export LianCoreHealth
// HealthCheck runs a real URL test through the current outbound.
func LianCoreHealth() *C.char {
	state.mu.Lock()
	running := state.running
	state.mu.Unlock()
	if running {
		triggerHealthCheck(5 * time.Second)
	}
	payload, _ := json.Marshal(collectHealth())
	return cstr(string(payload))
}

//export LianCoreStart
func LianCoreStart(configPathC, homeDirC *C.char, fd C.int) *C.char {
	configPath := C.GoString(configPathC)
	homeDir := C.GoString(homeDirC)
	state.mu.Lock()
	defer state.mu.Unlock()

	state.lastError = ""
	if state.running {
		state.lastError = "core already running"
		payload, _ := json.Marshal(bridgeStatusLocked())
		return cstr(string(payload))
	}
	if fd <= 0 {
		state.lastError = "invalid tun fd"
		payload, _ := json.Marshal(bridgeStatusLocked())
		return cstr(string(payload))
	}
	if homeDir == "" {
		homeDir = configPath
	}
	if err := os.MkdirAll(homeDir, 0o700); err != nil {
		state.lastError = fmt.Sprintf("create home dir: %v", err)
		payload, _ := json.Marshal(bridgeStatusLocked())
		return cstr(string(payload))
	}
	cconstant.SetHomeDir(homeDir)
	cconstant.SetConfig(configPath)

	buf, err := os.ReadFile(configPath)
	if err != nil {
		state.lastError = fmt.Sprintf("read config: %v", err)
		payload, _ := json.Marshal(bridgeStatusLocked())
		return cstr(string(payload))
	}
	raw, err := config.UnmarshalRawConfig(buf)
	if err != nil {
		state.lastError = fmt.Sprintf("parse config: %v", err)
		payload, _ := json.Marshal(bridgeStatusLocked())
		return cstr(string(payload))
	}
	raw.Tun.Enable = true
	// OpenHarmony's VPN fd is a platform-owned special descriptor. A host-side
	// socketpair test cannot prove that dup(2) preserves its bidirectional VPN
	// semantics. Pass the original descriptor to sing-tun; recovery must rebuild
	// the system TUN instead of reusing this descriptor after core teardown.
	raw.Tun.FileDescriptor = int(fd)
	raw.Tun.Stack = cconstant.TunGvisor
	raw.Tun.AutoRoute = false
	raw.Tun.AutoDetectInterface = false
	raw.Tun.AutoRedirect = false
	raw.Tun.StrictRoute = false
	if raw.Tun.MTU == 0 {
		raw.Tun.MTU = 1400
	}
	if len(raw.Tun.DNSHijack) == 0 {
		raw.Tun.DNSHijack = []string{"any:53"}
	}
	raw.Tun.EndpointIndependentNat = true
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		state.lastError = fmt.Sprintf("parse tun config: %v", err)
		payload, _ := json.Marshal(bridgeStatusLocked())
		return cstr(string(payload))
	}
	hub.ApplyConfig(cfg)
	if !listener.GetTunConf().Enable {
		executor.Shutdown()
		state.lastError = "tun listener failed to start"
		payload, _ := json.Marshal(bridgeStatusLocked())
		return cstr(string(payload))
	}

	state.running = true
	state.fd = int(fd)
	state.configPath = configPath
	payload, _ := json.Marshal(bridgeStatusLocked())
	return cstr(string(payload))
}

//export LianCoreStop
func LianCoreStop() {
	state.mu.Lock()
	defer state.mu.Unlock()
	if !state.running {
		return
	}
	state.lastError = ""
	if err := applyStopConfig(); err != nil {
		state.lastError = fmt.Sprintf("stop core: %v", err)
	}
	state.running = false
	state.fd = 0
	state.configPath = ""
	resetCoreHealth()
}

// resetCoreHealth 清空健康探测结果与连续失败计数。
//
// 必须在下一次 start 前调用：否则自愈重建（stop → start）后会带着上一轮
// 残留的 failStreak，使新核心刚起来就可能因一次抖动被立刻判 fail。
func resetCoreHealth() {
	coreHealth.mu.Lock()
	defer coreHealth.mu.Unlock()
	coreHealth.generation++
	coreHealth.checking = false
	coreHealth.state = "unknown"
	coreHealth.delay = 0
	coreHealth.checked = 0
	coreHealth.detail = ""
	coreHealth.failStreak = 0
}

//export LianCoreFree
func LianCoreFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
