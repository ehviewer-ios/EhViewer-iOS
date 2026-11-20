// 设备间 WiFi 互传（对应 Android client/wifi + ui/wifi）。
// - 帧协议 / JSON 消息 / 迁移文件工具 / 协议引擎：EhCore/Transfer（纯 Foundation，可在 Linux 测试）
// - 数据库存储与会话：TransferSession.swift
// - 传输层（Network.framework）：TransferServer / TransferClient / TransferConnection
@_exported import EhCore
@_exported import EhStorage
