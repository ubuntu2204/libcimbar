Debug Report: libcimbar_js_interop.dart IDE 失败标签
Status: RESOLVED  Date: 2026-07-11
Target: lib/src/web/libcimbar_js_interop.dart
Symptom: Trae IDE 该文件 3 处 失败 FileStatus 标签, 本机写失败.
Repro:
1. Trae IDE 打开文件
2. 侧栏/标题栏出现 3 个 失败 标签
3. Hover 可见 FileStatus 文案
Env: Ubuntu+libcimbar F/D. 文件 407 行/12999 字节, ubuntu:ubuntu. LSP: dart language-server PID 126368.
Hypotheses & Evidence:
H1 权限: 目录 775、文件 664, touch+tee 写测试通过 → 排除
H2 磁盘: 1.4 TB 可用, inode 2% → 排除
H3 文件锁: lsof 无结果, LSP 未持 fd → 排除
H4 LSP 失败: dart analyze → No issues found → 排除
H5 Git 锁: git status 干净, 100644 → 排除
Root Cause: 5 维度全正常. 失败 = Trae IDE FileStatus transient cosmetic 状态, 非真实写盘失败. 常见触发:
1. LSP 重启: pub get 重启 LSP 时 IDE 短暂标 未同步
2. inotify watcher 抖动: 短暂断开后重连
3. IDE cache 与磁盘 race
Fix 步骤:
1. Ctrl+S 强制重新保存 (最轻量)
2. 关闭 tab 重新打开 (干净)
3. Developer: Reload Window (彻底)
4. dart analyze 项目根 (触发 LSP 重 push)
Verification: Fix 1 后: 标签恢复; analyze 仍 No issues found; 文件不变.
Conclusion: IDE FileStatus transient 状态, 无需改代码. 反复走 Fix 3 兜底.