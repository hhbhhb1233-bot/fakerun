# fakerun — 雷电模拟器虚拟跑步

## 项目目标

通过 `ldconsole locate` 向雷电模拟器 GNSS HAL 层注入 GPS 坐标，实现无法被 App 检测为模拟定位的虚拟跑步。核心用户是浙江大学学生，用于"浙大体艺"App 的跑步打卡。

## 主要目录

```
/
├── fk-gps/fakerun/ldplayer_run/
│   ├── main.py           # 主程序：坐标转换、插值、噪声、定位注入
│   ├── config.yaml       # 配置：速度、间隔、噪声、连接方式
│   └── route.txt         # 路线数据（BD-09 百度坐标系，浙大操场）
├── install_magisk_to_emulator.bat   # Magisk Delta 安装脚本（Windows）
├── install_system.sh               # Magisk 系统模式安装脚本
└── CLAUDE.md                       本文件
```

## 常用命令

```bash
# 虚拟跑步（默认配置）
cd fk-gps/fakerun/ldplayer_run
python main.py

# 只跑一圈不循环
python main.py --no-loop

# 指定速度（散步/慢跑/快跑）
python main.py --speed 1.2   # 散步
python main.py --speed 3.0   # 慢跑（默认）
python main.py --speed 4.0   # 快跑

# 干运行（不发送定位，仅测试）
python main.py --dry-run

# 指定路线
python main.py --route route.txt

# 查看当前 git 状态
git status
```

## 允许修改的范围

只有在用户明确说"可以修改"或"可以编辑"之后才能修改，否则所有文件均视为只读。

可修改的文件（经用户授权后）：
- `fk-gps/fakerun/ldplayer_run/main.py` — 主程序逻辑
- `fk-gps/fakerun/ldplayer_run/config.yaml` — 默认配置
- `install_magisk_to_emulator.bat` — Magisk 安装脚本
- `install_system.sh` — 系统模式安装脚本
- `route.txt` — 路线数据

## 禁止触碰的文件

- `雷电模拟器/` — 便携版模拟器（几 GB，不在 git 中）
- `.git/` — git 对象数据库
- `.claude/` — Claude 配置和记忆

## 完成任务前必须执行的验证

1. **运行 dry-run 确认无报错**
   ```bash
   cd fk-gps/fakerun/ldplayer_run
   python main.py --dry-run --no-loop
   ```
2. **确认 git 工作区干净**（如修改了文件）
   ```bash
   git status
   ```
3. **检查语法 / import 正确性**
   ```bash
   python -c "import ast; ast.parse(open('fk-gps/fakerun/ldplayer_run/main.py').read()); print('语法 OK')"
   ```
