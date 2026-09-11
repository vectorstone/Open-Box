import assert from 'node:assert/strict'
import test from 'node:test'
import { buildConfig } from './config.mjs'
import { createNode } from './node-model.mjs'

const nodes = [
  createNode({ tag: '美国-01', type: 'shadowsocks', server: 'a.com', server_port: 8388, fields: { method: 'aes-256-gcm', password: 'pw' }, source: 'clash' }),
  createNode({ tag: 'WG-01', type: 'wireguard', server: 'wg.com', server_port: 51820, fields: { private_key: 'p', peer_public_key: 'q', local_address: ['10.0.0.2/32'] }, source: 'clash' }),
]
const regionGroups = [{ name: '美国', type: 'urltest', nodeTags: ['美国-01'] }]
const profile = {
  ipv6: true,
  dns: { split: true, direct: '223.5.5.5', proxy: 'https://1.1.1.1/dns-query' },
  routing: { proxyTag: 'PROXY', categories: [], directRulesets: ['geosite-cn'], adBlock: false, fallback: 'PROXY' },
  rulesetDir: '/data/rulesets',
  clashApiSecret: 's3cr3t',
}

test('buildConfig 顶层结构', () => {
  const c = buildConfig({ nodes, regionGroups, profile })
  assert.equal(c.log.level, 'warn')
  assert.equal(c.inbounds[0].type, 'tun')
  assert.equal(c.inbounds[0].address.length, 2)                     // v4 + v6
  assert.equal(c.experimental.clash_api.external_controller, '127.0.0.1:9095')
  assert.equal(c.experimental.clash_api.secret, 's3cr3t')
  // wireguard 进 endpoints,不进 outbounds
  assert.ok(c.endpoints.some((e) => e.tag === 'WG-01'))
  assert.ok(!c.outbounds.some((o) => o.tag === 'WG-01'))
  // direct + PROXY selector + 美国 urltest + ss 节点
  assert.ok(c.outbounds.some((o) => o.tag === 'direct' && o.type === 'direct'))
  assert.ok(c.outbounds.some((o) => o.tag === 'PROXY' && o.type === 'selector'))
  assert.ok(c.outbounds.some((o) => o.tag === '美国-01' && o.type === 'shadowsocks'))
})

test('ipv6 关:tun address 仅 v4', () => {
  const c = buildConfig({ nodes, regionGroups, profile: { ...profile, ipv6: false } })
  assert.equal(c.inbounds[0].address.length, 1)
  assert.equal(c.dns.strategy, 'ipv4_only')
})

test('修复2: category.target 引用不存在的组时重映射为 proxyTag', () => {
  const profileWithDanglingTarget = {
    ...profile,
    routing: { ...profile.routing, categories: [{ ruleset: 'geosite-netflix', target: '不存在的组' }] },
  }
  const c = buildConfig({ nodes, regionGroups, profile: profileWithDanglingTarget })
  const rule = c.route.rules.find((r) => r.rule_set === 'geosite-netflix')
  assert.ok(rule)
  assert.equal(rule.outbound, 'PROXY')
})

test('修复2: fallback 引用不存在的 tag 时重映射为 proxyTag', () => {
  const profileWithDanglingFallback = {
    ...profile,
    routing: { ...profile.routing, fallback: '也不存在' },
  }
  const c = buildConfig({ nodes, regionGroups, profile: profileWithDanglingFallback })
  assert.equal(c.route.final, 'PROXY')
})

test('修复2: 合法 target/fallback 不被改写', () => {
  const profileWithValidTarget = {
    ...profile,
    routing: { ...profile.routing, categories: [{ ruleset: 'geosite-netflix', target: '美国' }], fallback: '美国' },
  }
  const c = buildConfig({ nodes, regionGroups, profile: profileWithValidTarget })
  const rule = c.route.rules.find((r) => r.rule_set === 'geosite-netflix')
  assert.equal(rule.outbound, '美国')
  assert.equal(c.route.final, '美国')
})

test('tun.autoRedirect 默认关闭,可开启', () => {
  const c1 = buildConfig({ nodes, regionGroups, profile })
  assert.equal(c1.inbounds[0].auto_redirect, undefined)
  const c2 = buildConfig({ nodes, regionGroups, profile: { ...profile, tun: { autoRedirect: true } } })
  assert.equal(c2.inbounds[0].auto_redirect, true)
})

test('dns.mode=hijack(默认)生成 hijack-dns 路由规则', () => {
  const c = buildConfig({ nodes, regionGroups, profile })
  assert.ok(c.route.rules.some((r) => r.action === 'hijack-dns'))
  assert.ok(!c.inbounds.some((i) => i.type === 'direct'))
})

test('dns.mode=dnsmasq: hijack 规则仅限 dns-in 入站(不自环),增 DNS 入站 127.0.0.1:7853', () => {
  const c = buildConfig({ nodes, regionGroups, profile: { ...profile, dns: { ...profile.dns, mode: 'dnsmasq' } } })
  const hijack = c.route.rules.find((r) => r.action === 'hijack-dns')
  assert.ok(hijack)
  assert.deepEqual(hijack.inbound, ['dns-in'])
  assert.ok(!hijack.protocol)
  const dnsIn = c.inbounds.find((i) => i.type === 'direct')
  assert.equal(dnsIn.listen, '127.0.0.1')
  assert.equal(dnsIn.listen_port, 7853)
})

// -------- 链式代理(profile.chain → 出站 detour) --------

const chainNodes = [
  ...nodes,
  createNode({ tag: '日本-01', type: 'shadowsocks', server: 'b.com', server_port: 8388, fields: { method: 'aes-256-gcm', password: 'pw' }, source: 'clash' }),
]
const chainRegionGroups = [...regionGroups, { name: '日本', type: 'urltest', nodeTags: ['日本-01'] }]
const withChain = (chain) => ({ ...profile, chain })

test('chain 缺省(老 profile 没有这个字段)不产出任何 detour', () => {
  const c = buildConfig({ nodes: chainNodes, regionGroups: chainRegionGroups, profile })
  assert.ok(c.outbounds.every((o) => o.detour === undefined))
  assert.ok(c.endpoints.every((e) => e.detour === undefined))
})

test('chain: 落地节点带上指向前置节点的 detour', () => {
  const c = buildConfig({
    nodes: chainNodes,
    regionGroups: chainRegionGroups,
    profile: withChain([{ landing: '美国-01', via: '日本-01' }]),
  })
  const landing = c.outbounds.find((o) => o.tag === '美国-01')
  assert.equal(landing.detour, '日本-01')
  // 前置自己不带 detour(它就是第一跳)
  assert.equal(c.outbounds.find((o) => o.tag === '日本-01').detour, undefined)
})

test('chain: 前置也可以是策略组', () => {
  const c = buildConfig({
    nodes: chainNodes,
    regionGroups: chainRegionGroups,
    profile: withChain([{ landing: '美国-01', via: '日本' }]),
  })
  assert.equal(c.outbounds.find((o) => o.tag === '美国-01').detour, '日本')
})

test('chain: 前置是包含落地自己的组(默认那个"自动组")→ 整条丢弃,否则内核 FATAL', () => {
  const autoGroup = [{ id: 'all-auto', name: '所有-自动', type: 'urltest', allNodes: true, members: [], interval: '3m', tolerance: 50 }]
  const c = buildConfig({
    nodes: chainNodes,
    regionGroups: chainRegionGroups,
    userGroups: autoGroup,
    profile: withChain([{ landing: '美国-01', via: '所有-自动' }]),
  })
  assert.equal(c.outbounds.find((o) => o.tag === '美国-01').detour, undefined)
})

test('chain: 落地或前置已经不存在(订阅刷新后) → 安静地不生成', () => {
  const c = buildConfig({
    nodes: chainNodes,
    regionGroups: chainRegionGroups,
    profile: withChain([
      { landing: '香港-01', via: '日本-01' },
      { landing: '美国-01', via: '香港-02' },
    ]),
  })
  assert.equal(c.outbounds.find((o) => o.tag === '美国-01').detour, undefined)
})

test('chain: 落地是策略组 → 不生成(组不吃 detour 字段,check 会直接报未知字段)', () => {
  const c = buildConfig({
    nodes: chainNodes,
    regionGroups: chainRegionGroups,
    profile: withChain([{ landing: '美国', via: '日本-01' }]),
  })
  assert.equal(c.outbounds.find((o) => o.tag === '美国').detour, undefined)
})

test('chain: wireguard 端点既可以是落地,也可以是前置', () => {
  const asLanding = buildConfig({
    nodes: chainNodes,
    regionGroups: chainRegionGroups,
    profile: withChain([{ landing: 'WG-01', via: '日本-01' }]),
  })
  assert.equal(asLanding.endpoints.find((e) => e.tag === 'WG-01').detour, '日本-01')

  const asVia = buildConfig({
    nodes: chainNodes,
    regionGroups: chainRegionGroups,
    profile: withChain([{ landing: '美国-01', via: 'WG-01' }]),
  })
  assert.equal(asVia.outbounds.find((o) => o.tag === '美国-01').detour, 'WG-01')
})

test('chain: 订阅自带的 detour(clash dialer-proxy / sing-box JSON)原样进配置', () => {
  const nativeNodes = [
    createNode({ tag: '前置', type: 'shadowsocks', server: 'a.com', server_port: 8388, fields: { method: 'aes-256-gcm', password: 'pw' }, source: 'clash' }),
    createNode({ tag: '落地', type: 'shadowsocks', server: 'b.com', server_port: 8388, fields: { method: 'aes-256-gcm', password: 'pw', detour: '前置' }, source: 'clash' }),
  ]
  const c = buildConfig({ nodes: nativeNodes, regionGroups: [], profile })
  assert.equal(c.outbounds.find((o) => o.tag === '落地').detour, '前置')
})
