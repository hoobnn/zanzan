@testable import zanzan

/// 测试 target 内消歧：zanzan 在此为普通 import，与 Testing/Foundation 的同名类型平级，
/// 本地 typealias 让模型名在测试代码里恢复无歧义。
typealias Category = zanzan.Category
typealias Tag = zanzan.Tag
