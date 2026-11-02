# W Sub · Android（待开发）

这个目录留给 Android 端。现在还没有代码，只放规划与约定。

- 技术选型建议：Kotlin + Jetpack Compose + `kotlinx.serialization` + SAF + Android Keystore。
- 必须与 iOS 共用同一种 `.vault` 文件，规格见 [`docs/vault-format.md`](../../docs/vault-format.md)。
- 服务清单与品牌图标不要另抄，直接读 [`shared/catalog`](../../shared/catalog)。
- 模块划分与迁移步骤见 [`docs/porting-android.md`](../../docs/porting-android.md)。

建议起点：先建 `core`（Money / BillingCycle / Models）并把 iOS 的周期与金额用例平移成 JUnit 测试，再动 UI。
