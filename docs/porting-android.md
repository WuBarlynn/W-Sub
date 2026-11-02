# Android 移植说明

这个仓库按「一个产品、两端实现、共享资产与格式」组织。Android 端不是翻译 Swift 代码，而是**按同一份规格重写**，复用不变的部分。

## 1. 目录约定

```
apps/ios/           iOS 工程（Xcode）
apps/android/       Android 工程（待建）
packages/           Swift 包（仅 iOS 使用）
shared/catalog/     平台无关：服务清单 + 品牌 SVG（两端都读）
docs/               规格文档（两端共同遵守）
tools/              资产生成脚本（生成 shared/ 与 iOS 资源）
```

`shared/catalog/services.json` 是服务清单的**唯一真源**（177 条：id / 名称 / 分类 / 品牌色 / 图标文件 / 别名 / 默认周期）。Android 直接用它渲染模板页，不要另抄一份。

`shared/catalog/brands/*.svg` 是全彩品牌图标原文件，Android 用 `coil-svg` 或 `androidsvg` 加载即可。

## 2. 模块映射

| iOS（Swift） | Android（Kotlin） | 说明 |
|---|---|---|
| `WSCore/Money` | `core/Money.kt` | 金额用 `Long` minor units + `Currency`，禁用 `Double` |
| `WSCore/BillingCycle` | `core/BillingCycle.kt` | 月末夹取、闰年规则必须一致，用同一批用例做单测 |
| `WSCore/Models` | `core/model/*.kt` | `kotlinx.serialization`，字段名与 JSON 完全一致 |
| `WSCore/SchemaMigrator` | `core/SchemaMigrator.kt` | `schemaVersion` 单调，未知版本拒绝打开 |
| `WSCore/LWWMerger` | `core/LwwMerger.kt` | 合并规则：updatedAt 大者胜，平局比 deviceID |
| `WSCrypto` | `crypto/VaultKeyring.kt` | 见下节 |
| `WSVault` | `vault/VaultStore.kt` | SAF + 协程串行化 |
| `WSDesignSystem` + `WSFeatures` | `ui/`（Compose） | 视觉对齐，不追求代码同构 |

## 3. 加密对应关系

| 能力 | iOS | Android |
|---|---|---|
| AES-256-GCM | CryptoKit | `javax.crypto.Cipher("AES/GCM/NoPadding")` |
| PBKDF2-HMAC-SHA256 | 自实现（CryptoKit HMAC） | `SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")` |
| HKDF-SHA256 | CryptoKit | 手写（约 40 行）或用 Tink |
| P-256 ECDH | CryptoKit | `KeyPairGenerator("EC")` + `KeyAgreement("ECDH")` |
| 生物识别保护私钥 | Secure Enclave + `biometryCurrentSet` | Android Keystore + `setUserAuthenticationRequired(true)` + `setInvalidatedByBiometricEnrollment(true)` |
| 随机数 | `SecRandomCopyBytes` | `SecureRandom` |

**文件格式必须逐字节一致**（见 `docs/vault-format.md`）。建议先写一个「读取 iOS 生成的 .vault」的测试，再写写入。

## 4. 存储

iOS 用 security-scoped bookmark 认文件夹；Android 用 Storage Access Framework：

```kotlin
val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
    context.contentResolver.takePersistableUriPermission(
        uri!!, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    )
}
```

- 写文件用 `contentResolver.openOutputStream(uri, "wt")`，先写临时 Document 再替换，保留 `.bak`。
- 权限可能在重启后失效（用户删了目录），必须做「重新授权」兜底，和 iOS 一样。

## 5. 建议顺序

1. `core`：Money / BillingCycle / Models + 单测（把 iOS 的 51 个用例挑周期与金额部分平移）。
2. `crypto`：先实现「读」，用 iOS 导出的样本文件做兼容测试。
3. `vault`：SAF + 原子写 + 自动保存。
4. `ui`：Compose 先做「卡片列表 + 详情 + 编辑」，图标复用 `shared/catalog`。
5. 最后接生物识别与通知。

## 6. 两端共享的验证清单

- [ ] 同一密码在两端都能打开同一个 `.vault`
- [ ] 月末（1/31）与闰年（2/29）的下次扣款日一致
- [ ] 金额折算到分后完全相等（无浮点误差）
- [ ] 改密码后，恢复码仍然有效
- [ ] 篡改任意一个头部字节，两端都报「完整性校验失败」
