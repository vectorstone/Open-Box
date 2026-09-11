<template>
  <div class="card bg-base-100 border-base-300/60 border">
    <div class="card-body gap-2 p-4">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-base font-semibold">{{ $t('routingChainTitle') }}</h2>
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          :aria-label="$t('refresh')"
          :disabled="loading"
          @click="loadOptions"
        >
          <ArrowPathIcon
            class="h-3.5 w-3.5"
            :class="loading && 'animate-spin'"
          />
        </button>
      </div>
      <p class="text-base-content/60 text-xs">{{ $t('routingChainDescription') }}</p>

      <div
        v-if="loading"
        class="flex justify-center py-4"
      >
        <span class="loading loading-spinner loading-sm" />
      </div>

      <p
        v-else-if="loadError"
        class="text-error text-xs"
      >
        {{ loadError }}
      </p>

      <template v-else>
        <div
          v-if="rows.length === 0"
          class="text-base-content/50 text-xs"
        >
          {{ $t('routingChainEmpty') }}
        </div>

        <div
          v-for="(row, idx) in rows"
          :key="`${row.landing}-${idx}`"
          class="flex flex-col gap-1"
        >
          <div class="flex flex-wrap items-center gap-2">
            <label class="text-base-content/50 shrink-0 text-xs">{{ $t('routingChainLandingLabel') }}</label>
            <select
              class="select select-sm min-w-0 flex-1"
              :value="row.landing"
              :disabled="saving"
              @change="changeLanding(idx, ($event.target as HTMLSelectElement).value)"
            >
              <option
                v-for="node in availableNodes"
                :key="node.name"
                :value="node.name"
              >
                {{ node.name }}
              </option>
              <!-- 落地不在当前节点列表里时也要把它显示出来,否则下拉框会默默显示成第一个
                   节点、和下面的警告对不上 -->
              <option
                v-if="!nodeNames.has(row.landing)"
                :value="row.landing"
                disabled
              >
                {{ row.landing }}
              </option>
            </select>

            <ArrowRightIcon class="text-base-content/40 h-3.5 w-3.5 shrink-0" />

            <label class="text-base-content/50 shrink-0 text-xs">{{ $t('routingChainViaLabel') }}</label>
            <select
              class="select select-sm min-w-0 flex-1"
              :value="row.via"
              :disabled="saving"
              @change="changeVia(idx, ($event.target as HTMLSelectElement).value)"
            >
              <option
                v-for="target in viaOptions(row.landing)"
                :key="target"
                :value="target"
              >
                {{ target }}
              </option>
              <option
                v-if="!viaOptions(row.landing).includes(row.via)"
                :value="row.via"
                disabled
              >
                {{ row.via }}
              </option>
            </select>

            <button
              type="button"
              class="btn btn-ghost btn-xs btn-square"
              :aria-label="$t('routingChainRemove')"
              :disabled="saving"
              @click="removeChain(idx)"
            >
              <TrashIcon class="h-4 w-4" />
            </button>
          </div>

          <p
            v-if="row.warning"
            class="text-warning text-xs"
          >
            {{ row.warning }}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            class="btn btn-sm"
            :disabled="!canAdd || saving"
            @click="addChain"
          >
            <PlusIcon class="h-4 w-4" />
            {{ $t('routingChainAdd') }}
          </button>
          <span
            v-if="!canAdd"
            class="text-base-content/50 text-xs"
          >
            {{ $t('routingChainNeedTwoNodes') }}
          </span>
        </div>

        <p
          v-if="saveError"
          class="text-error text-xs"
        >
          {{ saveError }}
        </p>
      </template>
    </div>
  </div>
</template>

<script setup lang="ts">
import type { OpenboxProfile, OpenboxProfileChainEntry, OpenboxUserGroup } from '@/api/openbox'
import { fetchNodeGroups } from '@/api/openbox'
import { ArrowPathIcon, ArrowRightIcon, PlusIcon, TrashIcon } from '@heroicons/vue/24/outline'
import { computed, onMounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'

const props = defineProps<{
  profile: OpenboxProfile
  patchProfile: (patch: Record<string, unknown>) => Promise<OpenboxProfile>
}>()

const { t } = useI18n()

// -------- 可选目标:节点与用户策略组 --------

const availableNodes = ref<Array<{ name: string; subscription: string }>>([])
const availableGroups = ref<string[]>([])
const groups = ref<OpenboxUserGroup[]>([])
const loading = ref(false)
const loadError = ref('')

const loadOptions = async () => {
  loading.value = true
  loadError.value = ''
  try {
    const data = await fetchNodeGroups()
    availableNodes.value = data.availableNodes
    availableGroups.value = data.availableGroups
    groups.value = data.groups
  } catch (error) {
    loadError.value = t('routingChainLoadFailed', {
      message: error instanceof Error ? error.message : String(error),
    })
  } finally {
    loading.value = false
  }
}

onMounted(loadOptions)

const nodeNames = computed(() => new Set(availableNodes.value.map((n) => n.name)))
const groupNames = computed(() => new Set(availableGroups.value))
const groupByName = computed(() => new Map(groups.value.map((g) => [g.name, g])))

// 前置可选:所有节点 + 所有策略组。去重是为了防「组名恰好和某个节点同名」时出现重复
// option(那是份本身就无效的配置,但下拉框不该因此渲染出两个一样的选项)。
const allTargets = computed(() => Array.from(new Set([...nodeNames.value, ...availableGroups.value])))

// 自己不能当前置——那会成环,后端会直接把这条链路丢掉
const viaOptions = (landing: string) => allTargets.value.filter((name) => name !== landing)

// 至少要有两个可选目标(一个当落地、另一个当前置),且必须有一个真节点能当落地。
const canAdd = computed(() => allTargets.value.length >= 2 && nodeNames.value.size > 0)

// -------- 逐行校验(纯前端,不发额外请求) --------

const warningFor = (entry: OpenboxProfileChainEntry): string => {
  // 落地必须是节点:节点不存在、或名字恰好是某个策略组,后端都会把这条丢掉
  if (!nodeNames.value.has(entry.landing)) return t('routingChainMissingLanding')
  if (!nodeNames.value.has(entry.via) && !groupNames.value.has(entry.via)) return t('routingChainMissingVia')

  const viaGroup = groupByName.value.get(entry.via)
  if (viaGroup && (viaGroup.allNodes || viaGroup.members.includes(entry.landing))) {
    return t('routingChainViaContainsLanding')
  }
  // 前置和落地同名:自己连自己,同样成环,复用同一条警告
  if (entry.via === entry.landing) return t('routingChainViaContainsLanding')
  return ''
}

const chain = computed(() => props.profile.chain ?? [])
const rows = computed(() => chain.value.map((entry) => ({ ...entry, warning: warningFor(entry) })))

// -------- 保存:任何增删改都是「算出完整新数组 → 整份覆盖」 --------

const saveError = ref('')
const saving = ref(false)

const runChainPatch = async (next: OpenboxProfileChainEntry[]) => {
  saveError.value = ''
  saving.value = true
  try {
    await props.patchProfile({ chain: next })
    return true
  } catch (error) {
    saveError.value = t('routingSaveFailed', {
      message: error instanceof Error ? error.message : String(error),
    })
    return false
  } finally {
    saving.value = false
  }
}

const changeLanding = (idx: number, landing: string) => {
  void runChainPatch(
    chain.value.map((entry, i) => {
      if (i !== idx) return entry
      // 落地改成和当前前置同名会立刻成环,顺手把前置挪到另一个目标上
      const via = entry.via === landing ? (allTargets.value.find((name) => name !== landing) ?? '') : entry.via
      return { landing, via }
    }),
  )
}

const changeVia = (idx: number, via: string) => {
  void runChainPatch(chain.value.map((entry, i) => (i === idx ? { ...entry, via } : entry)))
}

const removeChain = (idx: number) => {
  void runChainPatch(chain.value.filter((_, i) => i !== idx))
}

const addChain = async () => {
  if (saving.value || !canAdd.value) return

  // 落地优先挑还没被别的链路用过的节点,前置挑一个和它不同的目标
  const used = new Set(chain.value.map((entry) => entry.landing))
  const landing = availableNodes.value.map((n) => n.name).find((name) => !used.has(name)) ?? ''
  if (!landing) return
  const via = allTargets.value.find((name) => name !== landing) ?? ''

  await runChainPatch([...chain.value, { landing, via }])
}
</script>
