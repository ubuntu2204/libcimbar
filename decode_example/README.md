# decode_example

libcimbar Web/Android 解码接收端示例应用。

## 运行

```bash
# Web


cd ~/project/libcimbar/decode_example
adb reverse tcp:8080 tcp:8080
flutter run -d web-server --release --web-port 8080 --web-hostname 0.0.0.0



flutter run -d chrome

# Android
flutter run -d <android-device-id>
```

## 功能

- 通过摄像头扫描 cimbar 条码
- 实时解码并恢复原始文件
- 支持截图保存摄像头帧用于调试
