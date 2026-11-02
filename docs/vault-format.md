# Vault 文件格式（v1）

iOS 与 Android 共用同一种文件，两端都能打开同一个 `.vault`。实现时不要改字节序或字段顺序——头部是**定长 + 长度前缀**混排的，顺序错一位就全解不开。

所有整数为大端（big-endian）。文件扩展名建议 `.vault`，文件名 `WSubscription.vault`。

## 1. 头部（明文，被 HeaderMAC 认证）

| 偏移 | 字段 | 类型 | 说明 |
|---:|---|---|---|
| 0 | magic | 4B | `57 53 56 4C`（`WSVL`） |
| 4 | formatVersion | u16 | 当前 `1` |
| 6 | flags | u16 | bit0 = 含生物识别包裹，bit1 = 含恢复码包裹 |
| 8 | kdfID | u8 | `2` = PBKDF2-HMAC-SHA256（`1` 预留 Argon2id） |
| 9 | iterations | u32 | 口令 KDF 轮数，iOS 默认 600000 |
| 13 | saltPass | 16B | 口令专用盐 |
| 29 | saltRecovery | 16B | 恢复码专用盐 |
| 45 | saltBio | 16B | 生物识别 KEK 的 HKDF 盐 |
| 61 | wrapPassLen | u16 | 固定 60 |
| 63 | wrapPass | 60B | 口令包裹的 MK：nonce(12) ‖ ct(32) ‖ tag(16) |
| 123 | wrapBioLen | u16 | `0` 或 `125` |
| 125 | wrapBio | len B | ephPub(65, X9.63) ‖ AES-GCM(KEK_bio, MK)(60) |
| … | wrapRecoveryLen | u16 | `0` 或 `60` |
| … | wrapRecovery | len B | nonce ‖ ct ‖ tag |
| … | revision | u64 | 单调递增，每次落盘 +1 |
| … | writerDeviceID | 16B | UUID 原始字节 |
| … | payloadNonce | 12B | |
| … | headerMAC | 32B | HMAC-SHA256(HeaderMACKey, 前面所有字节) |

`headerMAC` **不在** MAC 覆盖范围内；它之后的全部字节是加密负载。

## 2. 密钥派生

```
KEK_pass     = PBKDF2-HMAC-SHA256(passphrase_utf8_nfc, saltPass, iterations, 32)
KEK_recovery = PBKDF2-HMAC-SHA256("ws.recovery.v1|" + normalized_code, saltRecovery, iterations, 32)
shared       = ECDH(P-256, device_private_key, ephPub)
KEK_bio      = HKDF-SHA256(ikm = shared, salt = saltBio, info = "ws.bio.kek.v1", 32)
MK           = AES-256-GCM-open(KEK_x, wrap_x)      // 三种路径任选其一
```

`normalized_code`：恢复码 24 字符，去分隔符、转大写，`I/L→1`、`O→0`（Crockford Base32）。

## 3. 负载

```
PayloadKey    = HKDF-SHA256(MK, salt = empty, info = "ws.payload.v1", 32)
HeaderMACKey  = HKDF-SHA256(MK, salt = empty, info = "ws.header.mac.v1", 32)
plaintext     = AES-256-GCM-open(PayloadKey, nonce = payloadNonce,
                                 aad = 头部前 N 字节（不含 headerMAC）,
                                 ct‖tag = 文件剩余字节)
```

明文是 UTF-8 JSON（字段见 `docs/data-model.md`），键名小驼峰，日期为 Unix 秒（浮点）。

## 4. 校验顺序（重要）

1. 读 magic / version，版本高于自己支持的直接拒绝（防止新版字段被旧版静默丢弃）。
2. 解包 MK（失败 = 凭据错误）。
3. 用 MK 校验 `headerMAC`（失败 = 文件被篡改或降级，**不要**计入密码错误次数）。
4. 解密负载（失败 = 文件损坏）。
5. 比对 `revision` 与本机记录，更旧则提示「可能来自备份」。

## 5. 注意

- 头部字段一旦变更必须提升 `formatVersion`；`kdfID` 用于替换 KDF 而不动格式。
- 改密码 / 换指纹 / 换恢复码都只重新包裹 MK，**不重新加密负载**。
- 写入必须是「临时文件 + 原子替换」，并保留上一版为 `.bak`。
