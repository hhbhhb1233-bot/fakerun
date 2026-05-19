"""
雷电模拟器虚拟跑步 (LDPlayer Virtual Run)

通过 ADB emu geo fix / ldconsole 向模拟器发送 GPS 坐标更新，
实现比 TestProvider 更底层的定位模拟，第三方 App 无法检测。

用法:
  python main.py                    # 使用默认配置
  python main.py --speed 4.0        # 指定速度
  python main.py --route my.txt     # 指定路线
  python main.py --no-loop          # 只跑一圈
  python main.py --method adb       # 强制使用 ADB
"""

import argparse
import math
import random
import subprocess
import sys
import time
from pathlib import Path
from functools import lru_cache

try:
    import yaml
except ImportError:
    print("缺少依赖，请运行: pip install pyyaml geopy")
    sys.exit(1)

try:
    from geopy.distance import geodesic
except ImportError:
    print("缺少依赖，请运行: pip install pyyaml geopy")
    sys.exit(1)


# ============================================================
# 坐标转换 (BD-09 → GCJ-02 → WGS-84)
# 百度地图取的点是 BD-09，模拟器需要 WGS-84
# ============================================================

def bd09_to_wgs84(lng: float, lat: float) -> tuple:
    """BD-09 → WGS-84 坐标转换"""
    x_pi = math.pi * 3000.0 / 180.0
    pi = math.pi
    a = 6378245.0
    ee = 0.00669342162296594323

    x = lng - 0.0065
    y = lat - 0.006
    z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * x_pi)
    theta = math.atan2(y, x) - 0.000003 * math.cos(x * x_pi)
    gcj_lng = z * math.cos(theta)
    gcj_lat = z * math.sin(theta)

    d_lat = _transform_lat(gcj_lng - 105.0, gcj_lat - 35.0)
    d_lng = _transform_lon(gcj_lng - 105.0, gcj_lat - 35.0)

    rad_lat = gcj_lat / 180.0 * pi
    magic = math.sin(rad_lat)
    magic = 1 - ee * magic * magic
    sqrt_magic = math.sqrt(magic)

    d_lng = (d_lng * 180.0) / (a / sqrt_magic * math.cos(rad_lat) * pi)
    d_lat = (d_lat * 180.0) / (a * (1 - ee) / (magic * sqrt_magic) * pi)

    wgs_lat = gcj_lat * 2 - gcj_lat - d_lat
    wgs_lng = gcj_lng * 2 - gcj_lng - d_lng
    return wgs_lng, wgs_lat


@lru_cache(maxsize=1000)
def bd09_to_wgs84_cached(lng: float, lat: float) -> tuple:
    return bd09_to_wgs84(lng, lat)


def _transform_lat(x: float, y: float) -> float:
    ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    ret += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0
    ret += (160.0 * math.sin(y / 12.0 * math.pi) + 320 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0
    return ret


def _transform_lon(x: float, y: float) -> float:
    ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    ret += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0
    ret += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0
    return ret


# ============================================================
# 路线加载
# ============================================================

def load_route(filepath: str) -> list:
    """加载路线文件，返回 [(lng, lat), ...] 列表 (WGS-84 坐标)"""
    raw = Path(filepath).read_text(encoding="utf-8").strip()

    points = []
    # 支持 JSON 对象拼接格式: {"lng":...,"lat":...},{"lng":...,"lat":...}
    import re
    for m in re.finditer(r'"lng"\s*:\s*"?([^",}\s]+)"?\s*,\s*"lat"\s*:\s*"?([^",}\s]+)"?', raw):
        lng = float(m.group(1))
        lat = float(m.group(2))
        wgs_lng, wgs_lat = bd09_to_wgs84_cached(lng, lat)
        points.append((wgs_lng, wgs_lat))

    if not points:
        # 尝试纯 JSON 数组格式
        import json
        try:
            arr = json.loads(raw)
            for p in arr:
                wgs_lng, wgs_lat = bd09_to_wgs84_cached(float(p["lng"]), float(p["lat"]))
                points.append((wgs_lng, wgs_lat))
        except json.JSONDecodeError:
            pass

    if not points:
        print(f"错误: 无法解析路线文件 {filepath}")
        print("支持的格式: {\"lng\":...,\"lat\":...},{\"lng\":...,\"lat\":...} 或 JSON 数组")
        sys.exit(1)

    return points


def interpolate_route(points: list, speed: float, interval: float) -> list:
    """按速度插值，生成等距路径点"""
    step_distance = speed * interval
    if step_distance <= 0:
        step_distance = 1.0  # 防除零，fallback 到 1m/步
    result = []
    n = len(points)

    for i in range(n):
        a = points[i]
        b = points[(i + 1) % n]
        dist = geodesic((a[1], a[0]), (b[1], b[0])).m
        steps = max(1, round(dist / step_distance))

        for j in range(steps):
            t = j / steps
            lng = a[0] + (b[0] - a[0]) * t
            lat = a[1] + (b[1] - a[1]) * t
            result.append((lng, lat))

    return result


# ============================================================
# 定位发送器
# ============================================================

class LocationSender:
    def __init__(self, method="auto", device_serial="", emulator_index=0):
        self.method = method
        self.device_serial = device_serial
        self.emulator_index = emulator_index
        self.ldconsole_path = None
        self.adb_path = None
        self._resolve_method()

    def _resolve_method(self):
        if self.method == "auto":
            # 优先检查 ldconsole
            ld = self._find_ldconsole()
            if ld:
                self.method = "ldconsole"
                self.ldconsole_path = ld
                print(f"[定位] 使用 ldconsole ({ld})")
                return

            # 检查 adb
            adb = self._find_adb()
            if adb:
                self.method = "adb"
                self.adb_path = adb
                print(f"[定位] 使用 ADB ({adb})")
                return

            print("[警告] 未找到 ldconsole 或 adb，将尝试裸调 adb")
            self.method = "adb"
        elif self.method == "ldconsole":
            self.ldconsole_path = self._find_ldconsole()
            if self.ldconsole_path:
                print(f"[定位] 使用 ldconsole ({self.ldconsole_path})")
        elif self.method == "adb":
            self.adb_path = self._find_adb()

    def _find_adb(self):
        """查找 adb 可执行文件"""
        # 常见 adb 路径
        candidates = [
            "adb",
            "C:/Program Files (x86)/LDPlayer/adb.exe",
            "C:/Program Files/LDPlayer9/adb.exe",
            "C:/Program Files/LDPlayer8/adb.exe",
            str(Path.home() / "AppData/Local/Android/Sdk/platform-tools/adb.exe"),
            str(Path.home() / "AppData/Local/LDPlayer9/adb.exe"),
            # 项目内便携版 LDPlayer
            str(Path(__file__).parent.parent.parent / "leidian/LDPlayer9/adb.exe"),
            str(Path(__file__).parent.parent.parent.parent / "雷电模拟器/adb.exe"),
        ]
        for c in candidates:
            try:
                subprocess.run([c, "version"], capture_output=True, timeout=2)
                return c
            except (FileNotFoundError, subprocess.TimeoutExpired):
                continue
        return "adb"  # fallback，可能在 PATH 里

    def _find_ldconsole(self):
        """查找 ldconsole 可执行文件"""
        candidates = [
            "ldconsole",
            "C:/Program Files (x86)/LDPlayer/ldconsole.exe",
            "C:/Program Files/LDPlayer9/ldconsole.exe",
            "C:/Program Files/LDPlayer8/ldconsole.exe",
            str(Path.home() / "AppData/Local/LDPlayer9/ldconsole.exe"),
            # 项目内便携版 LDPlayer
            str(Path(__file__).parent.parent.parent / "leidian/LDPlayer9/ldconsole.exe"),
            str(Path(__file__).parent.parent.parent.parent / "雷电模拟器/ldconsole.exe"),
        ]
        for c in candidates:
            try:
                subprocess.run([c, "list"], capture_output=True, timeout=2)
                return c
            except (FileNotFoundError, subprocess.TimeoutExpired):
                continue
        return None

    def _adb_cmd(self):
        cmd = [self.adb_path or self._find_adb()]
        if self.device_serial:
            cmd += ["-s", self.device_serial]
        return cmd

    def send(self, lng: float, lat: float, repeat: int = 1, repeat_delay: float = 0.05) -> bool:
        """发送坐标，成功返回 True，失败返回 False。
        repeat: 每个坐标重复注入次数，防止 GNSS 信号间隙导致 App 回退网络定位。
        repeat_delay: 重复注入间隔秒数。
        """
        for i in range(repeat):
            if i > 0:
                time.sleep(repeat_delay)
            try:
                if self.method == "ldconsole":
                    ld = self.ldconsole_path or "ldconsole"
                    r = subprocess.run(
                        [ld, "locate",
                         "--index", str(self.emulator_index),
                         "--LLI", f"{lng:.7f},{lat:.7f}"],
                        capture_output=True, timeout=5
                    )
                else:
                    r = subprocess.run(
                        self._adb_cmd() + ["emu", "geo", "fix", f"{lng:.7f}", f"{lat:.7f}"],
                        capture_output=True, timeout=5
                    )

                if r.returncode != 0:
                    stderr = r.stderr.decode(errors="replace").strip()
                    print(f"\n[错误] 定位发送失败 (returncode={r.returncode})")
                    if stderr:
                        print(f"       {stderr}")
                    return False
            except subprocess.TimeoutExpired:
                print("\n[错误] 定位命令超时 (5s)")
                return False
            except FileNotFoundError:
                print(f"\n[错误] 找不到可执行文件: {self.method}")
                return False
        return True


# ============================================================
# 主逻辑
# ============================================================

def add_noise(lng: float, lat: float, noise_meters: float) -> tuple:
    """在坐标上加随机偏移 (米)，使轨迹更自然"""
    if noise_meters <= 0:
        return lng, lat
    angle = random.uniform(0, 2 * math.pi)
    # 在地球表面近似: 1° ≈ 111320m
    dlat = noise_meters * math.cos(angle) / 111320.0
    dlng = noise_meters * math.sin(angle) / (111320.0 * math.cos(math.radians(lat)))
    return lng + dlng, lat + dlat


def print_info(points, speed, interval, loop):
    total_dist = 0
    for i in range(len(points)):
        a = points[i]
        b = points[(i + 1) % len(points)]
        total_dist += geodesic((a[1], a[0]), (b[1], b[0])).m

    lap_time = total_dist / speed if speed > 0 else 0
    print(f"  路线点数: {len(points)}")
    print(f"  总距离:   {total_dist:.1f} m")
    print(f"  速度:     {speed} m/s ({speed * 3.6:.1f} km/h)")
    print(f"  每圈用时: {lap_time:.0f} s ({lap_time / 60:.1f} min)")
    print(f"  更新间隔: {interval}s")
    print(f"  循环:     {'是' if loop else '否'}")
    print()


def main():
    parser = argparse.ArgumentParser(description="雷电模拟器 虚拟跑步")
    parser.add_argument("--config", default="config.yaml", help="配置文件路径")
    parser.add_argument("--route", help="路线文件 (覆盖 config.yaml)")
    parser.add_argument("--speed", type=float, help="速度 m/s (覆盖 config.yaml)")
    parser.add_argument("--interval", type=float, help="更新间隔秒 (覆盖 config.yaml)")
    parser.add_argument("--method", choices=["adb", "ldconsole", "auto"], help="定位方式")
    parser.add_argument("--no-loop", dest="loop", action="store_false", help="不循环")
    parser.add_argument("--noise", type=float, help="抖动偏移米数 (覆盖 config.yaml)")
    parser.add_argument("--dry-run", action="store_true", help="仅测试，不发送定位")
    args = parser.parse_args()

    # 加载配置
    cfg_path = Path(args.config)
    cfg = {}
    if cfg_path.exists():
        cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}

    route_file = args.route or cfg.get("routeFile", "route.txt")
    speed = args.speed if args.speed is not None else cfg.get("speed", 3.3)
    interval = args.interval if args.interval is not None else cfg.get("interval", 1.0)
    loop = args.loop if args.loop is not None else cfg.get("loop", True)
    noise = args.noise if args.noise is not None else cfg.get("noise", 2.0)
    method = args.method or cfg.get("method", "auto")
    device_serial = cfg.get("deviceSerial", "")
    emulator_index = cfg.get("emulatorIndex", 0)

    # 加载路线
    if not Path(route_file).exists():
        # 尝试相对于脚本目录
        script_dir = Path(__file__).parent
        alt = script_dir / route_file
        if alt.exists():
            route_file = str(alt)
        else:
            print(f"错误: 路线文件不存在: {route_file}")
            sys.exit(1)

    print("=" * 50)
    print("  雷电模拟器 虚拟跑步  v1.0")
    print("=" * 50)
    print()

    raw_points = load_route(route_file)
    print(f"[路线] 已加载 {len(raw_points)} 个原始路径点")

    wgs_points = interpolate_route(raw_points, speed, interval)
    print_info(wgs_points, speed, interval, loop)

    dry_run = args.dry_run
    sender = None if dry_run else LocationSender(method, device_serial, emulator_index)

    if dry_run:
        print("[干运行模式] 仅展示坐标数据，不实际发送\n")
    else:
        # 启动前连通性测试
        print("[检测] 测试模拟器连通性...")
        test_lng, test_lat = wgs_points[0]
        if not sender.send(test_lng, test_lat, repeat=2):
            print("[错误] 模拟器未响应，请检查:")
            print("       1. 雷电模拟器是否已启动")
            print("       2. adb 是否已连接 (adb devices)")
            print("       3. config.yaml 中的 method/index/serial 是否正确")
            sys.exit(1)
        print("[检测] 模拟器连接正常\n")
        print("按 Ctrl+C 停止\n")
        time.sleep(1)

    lap = 0
    fail_count = 0
    max_fails = 5
    lap_offset_lng = 0.0
    lap_offset_lat = 0.0
    try:
        while True:
            lap += 1
            if lap > 1:
                # 每圈随机偏移 (0~3m)，防止路线完美重合触发反作弊
                angle = random.uniform(0, 2 * math.pi)
                offset_m = random.uniform(0.5, 3.0)
                lap_offset_lat = offset_m * math.cos(angle) / 111320.0
                lap_offset_lng = offset_m * math.sin(angle) / (111320.0 * math.cos(math.radians(wgs_points[0][1])))
                print(f"\n--- 第 {lap} 圈 (偏移 {offset_m:.1f}m) ---")
            else:
                print(f"\n--- 第 {lap} 圈 ---")

            for idx, (lng, lat) in enumerate(wgs_points):
                # 叠加每圈偏移 + 可变噪声 (0.5~base_noise*2 m)
                olng = lng + lap_offset_lng
                olat = lat + lap_offset_lat
                actual_noise = random.uniform(0.5, max(noise * 2, 1.0))
                nlng, nlat = add_noise(olng, olat, actual_noise)

                if dry_run:
                    if idx % 10 == 0 or idx == len(wgs_points) - 1:
                        progress = (idx + 1) / len(wgs_points) * 100
                        print(f"\r  [{progress:3.0f}%] ({nlat:.6f}, {nlng:.6f})    ", end="", flush=True)
                else:
                    ok = sender.send(nlng, nlat, repeat=2)
                    if not ok:
                        fail_count += 1
                        if fail_count >= max_fails:
                            print(f"\n[错误] 连续 {max_fails} 次发送失败，自动停止")
                            break
                    else:
                        fail_count = 0

                    if idx % 10 == 0 or idx == len(wgs_points) - 1:
                        progress = (idx + 1) / len(wgs_points) * 100
                        print(f"\r  进度: {progress:.0f}% | ({nlat:.6f}, {nlng:.6f})    ", end="", flush=True)

                # 速度抖动 ±18%，模拟自然跑速变化
                time.sleep(interval * random.uniform(0.82, 1.18))

                # 随机微停顿 (1.5%概率) 模拟等红灯/减速
                if not dry_run and random.random() < 0.015:
                    pause = random.uniform(2, 5)
                    print(f"\r  [停顿 {pause:.0f}s]   ", end="", flush=True)
                    time.sleep(pause)

            print()
            if not loop or fail_count >= max_fails:
                break

    except KeyboardInterrupt:
        print("\n\n已停止虚拟跑步")
        print("提示: 雷电模拟器的定位会自动保持最后一次设定的位置，无需额外清理")


if __name__ == "__main__":
    main()
