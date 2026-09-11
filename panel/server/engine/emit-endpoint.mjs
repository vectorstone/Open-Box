export const emitEndpoint = (node) => {
  if (node.type !== 'wireguard') throw new Error(`emitEndpoint only supports wireguard, got: ${node.type}`)
  const f = node.fields
  const peer = {
    address: node.server,
    port: node.server_port,
    public_key: f.peer_public_key,
    allowed_ips: ['0.0.0.0/0', '::/0'],
  }
  if (f.pre_shared_key) peer.pre_shared_key = f.pre_shared_key
  const endpoint = {
    type: 'wireguard',
    tag: node.tag,
    system: false,
    address: Array.isArray(f.local_address) ? f.local_address : [],
    private_key: f.private_key,
    peers: [peer],
  }
  // 与 emit-outbound.mjs 一致:wireguard 端点也吃 detour(实测 check 通过),订阅自带的
  // 链路信息原样带上,可用性由 chain.mjs 判定。
  if (typeof f.detour === 'string' && f.detour) endpoint.detour = f.detour
  return endpoint
}
