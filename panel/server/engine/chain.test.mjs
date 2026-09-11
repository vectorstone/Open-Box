import assert from 'node:assert/strict'
import test from 'node:test'
import { normalizeChain, resolveChain } from './chain.mjs'

// 一份"已经 emit 出来"的出站清单:组带 outbounds 成员,节点不带。
// 与真实生成结果同形(见 engine/config.mjs),chain.mjs 的依赖图就直接读它。
const outbounds = [
  { type: 'direct', tag: 'direct' },
  { type: 'selector', tag: 'PROXY', outbounds: ['G-ALL', 'JP', 'direct'] },
  { type: 'selector', tag: 'G-ALL', outbounds: ['US-01', 'JP-01'] },
  { type: 'urltest', tag: 'JP', outbounds: ['JP-01'] },
  { type: 'shadowsocks', tag: 'US-01' },
  { type: 'shadowsocks', tag: 'JP-01' },
  { type: 'shadowsocks', tag: 'SG-01' },
]

// -------- normalizeChain --------

test('normalizeChain 缺省/空数组都收敛成空链路', () => {
  assert.deepEqual(normalizeChain(undefined), { ok: true, chain: [] })
  assert.deepEqual(normalizeChain(null), { ok: true, chain: [] })
  assert.deepEqual(normalizeChain([]), { ok: true, chain: [] })
})

test('normalizeChain 非数组 → 报错', () => {
  assert.equal(normalizeChain({ 'US-01': 'JP-01' }).ok, false)
  assert.ok(normalizeChain('nope').error)
})

test('normalizeChain 每项必须是 { landing, via }', () => {
  assert.equal(normalizeChain(['US-01']).ok, false)
  assert.ok(normalizeChain([{ landing: 'US-01' }]).error)
  assert.ok(normalizeChain([{ via: 'JP-01' }]).error)
  assert.ok(normalizeChain([{ landing: 'US-01', via: '' }]).error)
  assert.ok(normalizeChain([{ landing: 'US-01', via: 1 }]).error)
})

test('normalizeChain 自指在写库前就被挡掉', () => {
  const r = normalizeChain([{ landing: 'US-01', via: 'US-01' }])
  assert.equal(r.ok, false)
  assert.match(r.error, /itself/)
})

test('normalizeChain 去空白;同一个落地写两遍以先写的为准', () => {
  const r = normalizeChain([
    { landing: ' US-01 ', via: ' JP-01 ' },
    { landing: 'US-01', via: 'direct' },
  ])
  assert.deepEqual(r.chain, [{ landing: 'US-01', via: 'JP-01' }])
})

// -------- resolveChain --------

test('resolveChain 基本链路:落地拿到指向前置的 detour', () => {
  const r = resolveChain({ outbounds, chain: [{ landing: 'US-01', via: 'JP-01' }] })
  assert.deepEqual(r.detour, { 'US-01': 'JP-01' })
  assert.deepEqual(r.dropped, [])
})

test('resolveChain 前置可以是组(只要组不包含落地)', () => {
  const r = resolveChain({ outbounds, chain: [{ landing: 'US-01', via: 'JP' }] })
  assert.deepEqual(r.detour, { 'US-01': 'JP' })
  assert.deepEqual(r.dropped, [])
})

test('resolveChain 落地必须是节点:组不吃 detour 字段', () => {
  const r = resolveChain({ outbounds, chain: [{ landing: 'PROXY', via: 'JP-01' }] })
  assert.deepEqual(r.detour, {})
  assert.deepEqual(r.dropped, [{ landing: 'PROXY', via: 'JP-01', reason: 'landing-is-group' }])
})

test('resolveChain 落地/前置不存在(订阅刷新后节点没了)→ 丢弃并说明', () => {
  const missingLanding = resolveChain({ outbounds, chain: [{ landing: '香港-01', via: 'JP-01' }] })
  assert.deepEqual(missingLanding.detour, {})
  assert.equal(missingLanding.dropped[0].reason, 'missing-landing')

  const missingVia = resolveChain({ outbounds, chain: [{ landing: 'US-01', via: '香港-01' }] })
  assert.deepEqual(missingVia.detour, {})
  assert.equal(missingVia.dropped[0].reason, 'missing-via')
})

test('resolveChain 前置是"包含落地的组"→ 成环,整条丢弃', () => {
  // 实测内核行为:check 通过,运行期 FATAL circular outbound dependency: US-01 -> G-ALL -> US-01
  const r = resolveChain({ outbounds, chain: [{ landing: 'US-01', via: 'G-ALL' }] })
  assert.deepEqual(r.detour, {})
  assert.deepEqual(r.dropped, [{ landing: 'US-01', via: 'G-ALL', reason: 'cycle' }])
})

test('resolveChain 两条链路互相咬住 → 后一条丢弃', () => {
  const r = resolveChain({
    outbounds,
    chain: [
      { landing: 'US-01', via: 'JP-01' },
      { landing: 'JP-01', via: 'US-01' },
    ],
  })
  assert.deepEqual(r.detour, { 'US-01': 'JP-01' })
  assert.deepEqual(r.dropped, [{ landing: 'JP-01', via: 'US-01', reason: 'cycle' }])
})

test('resolveChain 多跳链路可以同时成立', () => {
  const r = resolveChain({
    outbounds,
    chain: [
      { landing: 'US-01', via: 'JP-01' },
      { landing: 'JP-01', via: 'direct' },
    ],
  })
  assert.deepEqual(r.detour, { 'US-01': 'JP-01', 'JP-01': 'direct' })
  assert.deepEqual(r.dropped, [])
})

test('resolveChain 绕一圈回到落地(三跳)同样算成环', () => {
  const r = resolveChain({
    outbounds,
    chain: [
      { landing: 'US-01', via: 'JP-01' },
      { landing: 'JP-01', via: 'SG-01' },
      { landing: 'SG-01', via: 'US-01' },
    ],
  })
  assert.deepEqual(r.detour, { 'US-01': 'JP-01', 'JP-01': 'SG-01' })
  assert.deepEqual(r.dropped, [{ landing: 'SG-01', via: 'US-01', reason: 'cycle' }])
})

test('resolveChain 订阅自带的 detour 也进依赖图', () => {
  const withNative = [
    ...outbounds.filter((o) => o.tag !== 'JP-01'),
    { type: 'shadowsocks', tag: 'JP-01', detour: 'US-01' },
  ]
  const r = resolveChain({ outbounds: withNative, chain: [{ landing: 'US-01', via: 'JP-01' }] })
  assert.deepEqual(r.detour, {})
  assert.deepEqual(r.dropped, [{ landing: 'US-01', via: 'JP-01', reason: 'cycle' }])
})

test('resolveChain 用户链路覆盖订阅自带的 detour', () => {
  const withNative = [
    ...outbounds.filter((o) => o.tag !== 'US-01'),
    { type: 'shadowsocks', tag: 'US-01', detour: 'direct' },
  ]
  const r = resolveChain({ outbounds: withNative, chain: [{ landing: 'US-01', via: 'JP-01' }] })
  assert.deepEqual(r.detour, { 'US-01': 'JP-01' })
  assert.deepEqual(r.dropped, [])
})

test('resolveChain 结构不合法时安静地不产出任何链路', () => {
  const r = resolveChain({ outbounds, chain: 'nope' })
  assert.deepEqual(r.detour, {})
  assert.deepEqual(r.dropped, [])
})

test('resolveChain 缺省参数不炸', () => {
  assert.deepEqual(resolveChain(), { detour: {}, dropped: [] })
})
