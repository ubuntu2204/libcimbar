# libcimbar 项目规则：一切尽量向官方靠拢

**优先级：高。** 当本项目（libcimbar Flutter 移植）与官方实现存在任何行为、
性能、UI 或依赖差异时，默认结论是**官方是对的**，任务是向官方对齐，
不是为差异找辩护理由。曾因"中心方形裁剪 vs cfc 全帧扫描"被我误判为
"功能等价、纯视觉差异"，实为解码率差距（裁剪丢掉条码偏移时的整帧）。

## 官方参照物（按平台）

| 平台 | 官方实现 | 位置 |
|---|---|---|
| Android | cfc（CameraFileCopy） | `third_party/cfc/` |
| Web | recv.html / recv.js / recv-worker.js | `third_party/libcimbar/web/`（及 `~/下载/cimbar.wasm/` 完整包） |
| C++ 核心 | libcimbar 本体 | `third_party/libcimbar/` |

## 行为准则

1. **先读官方源码再下结论**：任何"为什么官方 X 我们 Y"的问题，答案从
   官方源码里找，不从推测里找。
2. **逐项对齐，不自创替代**：相机约束、分辨率策略、方向锁定、帧调度、
   解码线程模型、UI 反馈（如三色 guidance）都以官方为唯一标准。
3. **已确立的对齐基线**（改动前先核对是否偏离）：
   - 安卓：**方向跟随设备**（竖屏/横屏皆可——官方 web 端 recv.js 的哲学；
     cfc 主线锁横屏是其 OpenCV SurfaceView 的 2020 年历史包袱，作者
     自己在未合并的 orientation-station 分支里尝试过删除；扫描中旋转
     需重启相机控制器，见 decoder_page didChangeMetrics）、
     全帧扫描（无中心裁剪）、短边 1080p 上限、I420 直送、
     **取景窗 = cfc 实测几何**：4:3 窗口填满屏幕短边居中（横屏 2412x1080
     屏 → 1440x1080，与官方像素级同尺寸）、纯黑不透明方角 letterbox、
     括号在**窗口角**（cfc drawGuidance 比例：stroke=minsz/128、
     length=stroke*8、offset=minsz/32、黑描边）；Scanner 仍扫全帧
     （视觉引导 ≠ 裁剪）
   - Web：rVFC 全帧调度、getUserMedia 约束照抄 recv.js、
     Worker 池并行解码、copyTo 不 await
   - UI：白/黄/绿三色 guidance 状态机（cfc drawGuidance 语义）、
     真实进度来自 `cimbard_get_report` 的 `[p1,p2,...]`
   - **截图对比方法论**：模型不能直接看图时，用 Python+numpy 做按列/行
     像素 std 剖面（相机内容 std>50 / 暗化 5-25 / 纯黑 <5）测量窗口
     几何，不靠肉眼猜
4. **third_party/ 目录只读**（既有铁律不变）；官方源码仅作参照与基准。
5. **对比工具**：`test/e2e/compare_web.py` 官方 vs 本项目网页端基准，
   任何解码相关改动后跑一次，防止回归。
