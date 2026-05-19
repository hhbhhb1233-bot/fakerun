# LDPlayer 虚拟跑步

基于雷电模拟器 GNSS HAL 层定位注入的虚拟跑步方案。

## 原理

通过 `ldconsole locate` 命令，将 GPS 坐标直接写入 LDPlayer 的 GNSS 硬件抽象层（`/dev/fastpipe`），App 看到的等同真实 GPS 芯片数据，**无法被检测为模拟定位**。

```
main.py → 读取路线 → BD-09→WGS-84 转换 → 按速度插值 → ldconsole locate
                                                          ↓
                                                   GNSS HAL 层
                                                          ↓
                                                  App 看到真实 GPS
```

## 项目结构

| 目录/文件 | 说明 |
|---|---|
| `fakerun/ldplayer_run/` | 虚拟跑步脚本 |
| `fakerun/ldplayer_run/main.py` | 主程序 |
| `fakerun/ldplayer_run/config.yaml` | 配置文件 |
| `fakerun/ldplayer_run/route.txt` | 路线数据（BD-09 格式） |
| `leidian/` | 便携版雷电模拟器 |

## 使用

```bash
# 确保模拟器已启动
cd fakerun/ldplayer_run
pip install pyyaml geopy

# 跑步（默认 3.3 m/s ≈ 12km/h 慢跑）
python main.py

# 散步
python main.py --speed 1.2

# 只跑一圈不循环
python main.py --no-loop

# 指定速度 + 路线
python main.py --speed 4.0 --route route.txt
```

## 配置项 `config.yaml`

| 参数 | 说明 | 默认值 |
|---|---|---|
| `speed` | 速度 (m/s)，3.3=慢跑 | 3.3 |
| `interval` | 更新间隔(秒)，越小越平滑 | 0.3 |
| `loop` | 是否循环 | true |
| `noise` | 坐标抖动(米)，更自然 | 2.0 |
| `method` | 定位方式: auto/adb/ldconsole | auto |

## 坐标说明

路线数据使用 **BD-09（百度坐标系）** 存储，脚本运行时自动转为 **WGS-84** 再注入。采集路线点可使用百度地图坐标拾取系统。
