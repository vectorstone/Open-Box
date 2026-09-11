// 链式代理(前置 → 落地)。
//
// 用户在 profile.chain 里写 { 落地节点tag: 前置节点或组tag },这里把它变成写进出站的
// sing-box 拨号字段 `detour:"前置tag"` —— 语义是「这条出站到自己服务器的连接,先经由
// 前置出站建立」,也就是流量先到前置、再由前置连落地。
//
// 为什么必须在这里自己校验(钦定内核 1.13.14 实测;设备上的 1.14.0 行为一致):
//   - detour 指向不存在的 tag:sing-box check **通过**,运行期才 FATAL
//     `dependency[x] not found for outbound[y]`
//   - detour 成环(含「落地 detour 指回一个包含自己的组」):check 同样通过,运行期才
//     FATAL `circular outbound dependency: a -> b -> a`
//   - 组(selector/urltest)根本不吃 detour 字段,check 直接报
//     `json: unknown field "detour"` —— 所以落地只能是节点(endpoint 可以)
// 结论与 user-groups.mjs 顶部那三条不变式一样:"生成的配置能过 check"不代表链路是对的,
// 只能在生成时自己挡掉。

const isNonEmptyString = (v) => typeof v === 'string' && v.trim().length > 0

// 结构收敛:只为"能安全落库"的最小形状负责(数组、每项是 { landing, via } 且都是非空
// 字符串、不自指)。更深一层的可用性(前置是否存在、是否成环)不在这里判——写库时看不到
// 当前节点与组(订阅随时会刷新),交给 resolveChain 在生成配置那一刻判定。
// 用数组而不是 { 落地: 前置 } 对象:store 的 deepMerge 对数组整体替换、对对象按键合并,
// 用对象的话删掉一条链路要连带整个对象一起重写才行(与 routing.categories 同一取舍)。
// 返回 { ok, chain } 或 { ok:false, error },error 可直接进 400 响应体。
export const normalizeChain = (raw) => {
  if (raw === undefined || raw === null) return { ok: true, chain: [] }
  if (!Array.isArray(raw)) return { ok: false, error: 'chain must be an array of { landing, via }' }

  const chain = []
  const seenLanding = new Set()
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      return { ok: false, error: 'chain entries must be objects like { landing, via }' }
    }
    if (!isNonEmptyString(entry.landing)) {
      return { ok: false, error: 'chain[].landing must be a non-empty node tag' }
    }
    if (!isNonEmptyString(entry.via)) {
      return { ok: false, error: `chain[${entry.landing}].via must be a non-empty outbound tag` }
    }
    const landing = entry.landing.trim()
    const via = entry.via.trim()
    if (landing === via) return { ok: false, error: `chain[${landing}] cannot point to itself` }
    // 一个落地只能有一个前置(节点只能有一个上游)。重复项以先写的为准,界面也不该产生。
    if (seenLanding.has(landing)) continue
    seenLanding.add(landing)
    chain.push({ landing, via })
  }
  return { ok: true, chain }
}

// 依赖图:出站 tag -> 它依赖的 tag 集合。
//   组(带 outbounds 数组)= 它的成员;节点 = 它自己的 detour(订阅自带的 detour /
//   dialer-proxy 已由 emit 写进对象里)。组的成员在这里读的是**已经 emit 出来**的那份,
//   所以 user-groups 过滤掉的悬空成员/空组不会出现在图里,图与实际配置一致。
const buildGraph = (outbounds) => {
  const tags = new Set()
  const groupTags = new Set()
  const edges = new Map()
  for (const o of outbounds) {
    if (!o || !isNonEmptyString(o.tag)) continue
    tags.add(o.tag)
    if (Array.isArray(o.outbounds)) {
      groupTags.add(o.tag)
      edges.set(o.tag, o.outbounds.filter(isNonEmptyString))
    } else if (isNonEmptyString(o.detour)) {
      edges.set(o.tag, [o.detour.trim()])
    }
  }
  return { tags, groupTags, edges }
}

// via 沿依赖边走能不能走回 target(即:落地经由前置拨号,而前置又(间接)依赖落地)。
// accepted 里是本次已经接纳的链路,它覆盖节点自带的 detour——节点只能有一个上游。
const dependsOn = (from, target, graph, accepted) => {
  const seen = new Set()
  const stack = [from]
  while (stack.length) {
    const cur = stack.pop()
    if (cur === target) return true
    if (seen.has(cur)) continue
    seen.add(cur)
    const next = accepted.has(cur) ? [accepted.get(cur)] : (graph.edges.get(cur) || [])
    for (const tag of next) {
      if (!seen.has(tag)) stack.push(tag)
    }
  }
  return false
}

// 把 profile.chain 解算成 { 出站tag: 前置tag }。
// outbounds 应当是"除 detour 之外已经成型"的那份出站清单(outbounds + endpoints 都传进来,
// wireguard 节点既可以是前置也可以是落地)。
// 返回 { detour, dropped }:detour 只含真正生效的条目;dropped 里每条都带 reason,
// 取值 missing-landing / missing-via / landing-is-group / cycle。(自指在 normalizeChain
// 就被挡掉了,写库时即报错,不会走到这里。)
export const resolveChain = ({ outbounds, chain } = {}) => {
  const list = Array.isArray(outbounds) ? outbounds : []
  const graph = buildGraph(list)
  const { ok, chain: wanted } = normalizeChain(chain)
  const detour = {}
  const dropped = []
  if (!ok) return { detour, dropped }

  const accepted = new Map()
  for (const { landing, via } of wanted) {
    if (graph.groupTags.has(landing)) {
      dropped.push({ landing, via, reason: 'landing-is-group' })
      continue
    }
    if (!graph.tags.has(landing)) {
      dropped.push({ landing, via, reason: 'missing-landing' })
      continue
    }
    if (!graph.tags.has(via)) {
      dropped.push({ landing, via, reason: 'missing-via' })
      continue
    }
    // 前置自己(或它引用的组)依赖落地时,这条链路会让内核 FATAL,整条丢弃。
    if (dependsOn(via, landing, graph, accepted)) {
      dropped.push({ landing, via, reason: 'cycle' })
      continue
    }
    accepted.set(landing, via)
    detour[landing] = via
  }
  return { detour, dropped }
}
