import Foundation

/// 多设备共用同一网盘目录时的合并：LWW-Element-Set + 墓碑。
/// 目标不是完整 CRDT，而是「确定性、可解释、不静默丢数据」。
public enum LWWMerger {
    public static let tombstoneRetention: TimeInterval = 90 * 24 * 3600

    public static func merge(local: VaultSnapshot,
                             remote: VaultSnapshot,
                             now: Date = Date()) -> VaultSnapshot {
        var result = local
        result.schemaVersion = max(local.schemaVersion, remote.schemaVersion)

        // 1. 记录级合并：updatedAt 大者胜，相同则 deviceID 字典序大者胜（保证两台设备结果一致）
        var byID: [UUID: Subscription] = [:]
        for sub in local.subscriptions + remote.subscriptions {
            if let existing = byID[sub.id] {
                byID[sub.id] = isNewer(sub, than: existing) ? sub : existing
            } else {
                byID[sub.id] = sub
            }
        }

        // 2. 墓碑合并
        var tombstones: [UUID: Tombstone] = [:]
        for stone in local.tombstones + remote.tombstones {
            if let existing = tombstones[stone.id] {
                tombstones[stone.id] = stone.deletedAt > existing.deletedAt ? stone : existing
            } else {
                tombstones[stone.id] = stone
            }
        }

        // 3. 墓碑晚于最后修改 → 真正删除；否则说明删除后被重新编辑过，保留
        for (id, stone) in tombstones {
            if let sub = byID[id], sub.updatedAt >= stone.deletedAt { continue }
            byID[id] = nil
        }

        // 4. 清理过期墓碑
        let alive = tombstones.values.filter { now.timeIntervalSince($0.deletedAt) < tombstoneRetention }

        result.subscriptions = byID.values.sorted { $0.createdAt > $1.createdAt }
        result.tombstones = alive.sorted { $0.deletedAt > $1.deletedAt }

        // 5. 分类：并集，冲突时以本机为准（用户在这台设备上改的）
        var categories = local.categories
        let localIDs = Set(categories.map(\.id))
        categories += remote.categories.filter { !localIDs.contains($0.id) }
        result.categories = categories.sorted { $0.sortIndex < $1.sortIndex }

        // 6. 用户模板：并集，按创建时间取新
        var templates: [UUID: UserTemplate] = [:]
        for template in local.templates + remote.templates {
            if let existing = templates[template.id] {
                templates[template.id] = template.createdAt > existing.createdAt ? template : existing
            } else {
                templates[template.id] = template
            }
        }
        result.templates = templates.values.sorted { $0.createdAt > $1.createdAt }

        // 7. 设置：以本机为准，汇率取并集（远端补齐本机没有的币种）
        var settings = local.settings
        for (code, rate) in remote.settings.manualRates where settings.manualRates[code] == nil {
            settings.manualRates[code] = rate
        }
        result.settings = settings

        return result
    }

    public static func isNewer(_ lhs: Subscription, than rhs: Subscription) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.deviceID.uuidString > rhs.deviceID.uuidString
    }
}

public extension VaultSnapshot {
    /// 删除一条订阅：移除记录并写入墓碑（供合并使用）。
    mutating func removeSubscription(id: UUID, deviceID: UUID, now: Date = Date()) {
        subscriptions.removeAll { $0.id == id }
        tombstones.removeAll { $0.id == id }
        tombstones.append(Tombstone(id: id, deletedAt: now, deviceID: deviceID))
    }

    /// 新增或替换（保留 updatedAt 语义）。
    mutating func upsert(_ subscription: Subscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
        } else {
            subscriptions.append(subscription)
        }
    }
}
