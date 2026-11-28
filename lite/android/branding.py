"""Android 品牌资源：只替换用户可见内容，保留应用 ID、协议及上游许可。"""
import hashlib
import re
from pathlib import Path

from PIL import Image, ImageDraw

NAME = "在一起"
INPUT = "在一起（远程操作）"
ICON_SHA256 = "92188dadfe8f12524408a48f64f646280773728f05809e598f43299765ffb952"


def replace(path, old, new):
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise RuntimeError(f"品牌替换锚点变化: {path}: {old[:100]}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def apply(src, icon):
    """覆盖启动图、权限资源、通知频道、悬浮球和 Flutter 品牌。"""
    if hashlib.sha256(icon.read_bytes()).hexdigest() != ICON_SHA256:
        raise ValueError("应用图标校验失败")
    image = Image.open(icon).convert("RGB")
    res = src / "flutter/android/app/src/main/res"
    native = src / "flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb"
    flutter = src / "flutter"
    for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        folder = res / ("mipmap-" + density)
        for name in ("ic_launcher", "ic_launcher_round"):
            image.resize((size, size), Image.Resampling.LANCZOS).save(folder / (name + ".png"))
        # Adaptive launcher: keep the artwork inside the central safe area.
        extent = round(size * 108 / 48)
        safe = round(extent * 0.65)
        foreground = Image.new("RGBA", (extent, extent))
        foreground.paste(image.resize((safe, safe), Image.Resampling.LANCZOS), ((extent-safe)//2, (extent-safe)//2))
        foreground.save(folder / "ic_launcher_foreground.png")
        # Status bar / themed icons must be monochrome and have a transparent background.
        mono = Image.new("RGBA", (extent, extent))
        draw = ImageDraw.Draw(mono)
        draw.ellipse((extent*.22, extent*.25, extent*.53, extent*.56), fill="white")
        draw.ellipse((extent*.47, extent*.25, extent*.78, extent*.56), fill="white")
        draw.polygon([(extent*.25, extent*.45), (extent*.75, extent*.45), (extent*.5, extent*.77)], fill="white")
        mono.save(folder / "ic_launcher_monochrome.png")
        stat = round(size / 2)
        mono.resize((stat, stat), Image.Resampling.LANCZOS).save(folder / "ic_stat_logo.png")
    for path in (res / "mipmap-anydpi-v26").glob("ic_launcher*.xml"):
        replace(path, 'android:drawable="@mipmap/ic_launcher_foreground"/>\n</adaptive-icon>', 'android:drawable="@mipmap/ic_launcher_monochrome"/>\n</adaptive-icon>')
    (res / "values/ic_launcher_background.xml").write_text(
        '<resources><color name="ic_launcher_background">#318DF1</color></resources>\n', encoding="utf-8")
    (res / "drawable/floating_window.xml").unlink()
    image.resize((144, 144), Image.Resampling.LANCZOS).save(res / "drawable/floating_window.png")
    image.save(flutter / "assets/icon.png")
    for name in ("logo", "logo_light", "logo_dark"):
        image.save(flutter / f"assets/{name}.png")
    # 旧 SVG 仅用于回退和遗留控件；改为简洁的同品牌心形图标。
    (flutter / "assets/icon.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#318DF1"/><path d="M32 51 13 32C0 12 24 5 32 21 40 5 64 12 51 32Z" fill="#fff"/></svg>', encoding="utf-8")
    for folder in ("drawable", "drawable-v21"):
        (res / folder / "launch_background.xml").write_text(
            '<layer-list xmlns:android="http://schemas.android.com/apk/res/android"><item android:drawable="@android:color/white"/><item android:width="96dp" android:height="96dp" android:gravity="center" android:drawable="@mipmap/ic_launcher"/></layer-list>\n', encoding="utf-8")
    strings = res / "values/strings.xml"
    strings.write_text(
        '<resources>\n'
        '    <string name="app_name">在一起</string>\n'
        '    <string name="accessibility_service_name">在一起（远程操作）</string>\n'
        '    <string name="accessibility_service_description">开启后，在您同意远程协助并共享屏幕时，受您授权的对方可以查看屏幕、点击、滑动和输入文字。您可随时结束协助或在系统设置中关闭此权限。</string>\n'
        '</resources>\n', encoding="utf-8")
    manifest = src / "flutter/android/app/src/main/AndroidManifest.xml"
    replace(manifest, 'android:label="RustDesk Input"', 'android:label="@string/accessibility_service_name"')
    replace(manifest, 'android:label="远程协助"', 'android:label="@string/app_name"')
    replace(manifest, 'android:roundIcon="@mipmap/ic_launcher"', 'android:roundIcon="@mipmap/ic_launcher_round"')
    service = native / "MainService.kt"
    replace(service, 'const val DEFAULT_NOTIFY_TITLE = "RustDesk"', 'const val DEFAULT_NOTIFY_TITLE = "在一起"')
    # Channel ID is internal and kept for existing notification preferences; labels are not.
    replace(service, 'val channelName = "RustDesk Service"', 'val channelName = "在一起 · 远程协助"')
    replace(service, 'description = "RustDesk Service Channel"', 'description = "显示远程协助连接和屏幕共享状态"')
    replace(service, '"RustDeskVD"', '"在一起屏幕共享"')
    # Keep internal APP_NAME (SindreDeskLite) to avoid changing storage/identity paths.
    lang = src / "src/lang.rs"
    replace(lang, '        s\n    };', '''        if cfg!(target_os = "android") && name != "powered_by_me" {
            s = s.replace("SindreDeskLite Input", "在一起（远程操作）");
            s = s.replace("RustDesk Input", "在一起（远程操作）");
            s = s.replace("SindreDeskLite", "在一起").replace("RustDesk", "在一起");
        }
        s
    };''')
    # Permission guidance must use the exact Android settings service label.
    cn = src / "src/lang/cn.rs"
    replace(cn, "将 [RustDesk Input] 服务开启", "将 [在一起（远程操作）] 服务开启")
    replace(flutter / "lib/main.dart", ': bind.mainGetAppNameSync(),', ': (isAndroid ? "在一起" : bind.mainGetAppNameSync()),')
    replace(flutter / "lib/mobile/pages/home_page.dart", 'return Text(bind.mainGetAppNameSync());', 'return const Text("在一起");')
    replace(flutter / "lib/common.dart", 'Widget loadLogo() => const _Logo();', 'Widget loadLogo() => isAndroid ? Image.asset("assets/icon.png", width: 60, height: 60) : const _Logo();')
    # Static checks: allow upstream legal notices and internal names, not old visible permission labels.
    assert 'RustDesk Input' not in manifest.read_text(encoding="utf-8")
    assert 'RustDesk' not in strings.read_text(encoding="utf-8")
    assert 'channelName = "RustDesk' not in service.read_text(encoding="utf-8")
    print("在一起：Android 品牌及权限资源已生成")
