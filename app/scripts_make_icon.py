#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本地上下文 · App 图标生成器

为什么是脚本而不是一张图：图标要出 16/32/128/256/512/1024 六个尺寸，
手工导出既不可复现也容易漏；而且"哪一版更好"必须看着真实像素决定，
不能靠想象。改一行参数就能重新生成全部尺寸。

macOS 规格（Big Sur 及以后）：
  画布正方形，内容是一个 **超椭圆**（squircle），不是圆角矩形 ——
  圆角矩形在四个角会"方"得露馅，Apple 用的是连续曲率的形状。
  官方模板：内容区占画布的 824/1024，四边各留 100/1024。
  超椭圆 |x|^n + |y|^n = 1，n≈5 与 Apple 的形状非常接近。

坐标系只有一套：**所有尺寸都写成 1024 画布下的数，再乘以 S/1024。**
（第一版把"输出尺寸"和"超采样倍率"当成一回事，导致遮罩和盒子的尺寸对不上。）

用法：
    python3 scripts_make_icon.py              # 生成候选 + 各尺寸对比图
    python3 scripts_make_icon.py --pick A     # 导出 A 方案的 .icns 全套
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REF = 1024.0
# macOS 26 会把「legacy」图标放进一块浅色底板，并期望图形铺满它。
# 留白 100 的结果是：系统把那圈留白填成灰底板 → 深色 squircle 套在灰底板里，
# 双层圆角，很丑。Terminal 之所以正常，是因为它的图形本身就是满幅黑方块。
# 所以这里改成满幅：形状自己占满画布，圆角由我们的 squircle 负责。
INSET = 0.0
N_SQUIRCLE = 5.0
SS_MAX = 4

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "icon")
PREVIEW = os.path.join(OUT, "_candidates.png")

PALETTES = {
    "ink":   ((46, 49, 84), (22, 23, 40)),
    "slate": ((58, 60, 74), (30, 31, 40)),
    "dusk":  ((72, 52, 96), (30, 22, 46)),
}

GREEN = (52, 199, 89)
GRAY = (142, 142, 147)
ORANGE = (255, 159, 10)
WHITE = (255, 255, 255)


def f(v, S):
    return v / REF * S


def safe_font(size):
    """PIL 打不开 PingFang.ttc（TTC 容器）；逐个退到能用的字体，全不行就用默认。"""
    for cand in ["/System/Library/Fonts/Helvetica.ttc",
                 "/System/Library/Fonts/HelveticaNeue.ttc",
                 "/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/Library/Fonts/Arial.ttf"]:
        if os.path.exists(cand):
            try:
                return ImageFont.truetype(cand, size)
            except Exception:
                continue
    return ImageFont.load_default()


def squircle_pts(S, n=N_SQUIRCLE, steps=2048):
    r = S / 2.0
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = r * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = r * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((r + x, r + y))
    return pts


def gradient(S, top, bottom):
    g = Image.new("RGB", (1, S))
    px = g.load()
    for y in range(S):
        t = y / max(1, S - 1)
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return g.resize((S, S), Image.BICUBIC)


def base(palette, S):
    inset = int(round(f(INSET, S)))
    bw = S - 2 * inset
    m = Image.new("L", (bw, bw), 0)
    ImageDraw.Draw(m).polygon(squircle_pts(bw), fill=255)
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 投影：只一层，且只在有留白时画 —— 满幅时投影会被画布裁掉，系统自己会画
    if inset > 0:
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        sh.paste((0, 0, 0, 74), (inset, inset + int(f(16, S))), m)
        canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(f(18, S))))

    top, bot = PALETTES[palette]
    body = gradient(bw, top, bot).convert("RGBA")
    body.putalpha(m)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    layer.paste(body, (inset, inset))
    canvas.alpha_composite(layer)

    # 顶部内高光：让形状有厚度，而不是一块贴纸
    hl = Image.new("L", (bw, bw), 0)
    hd = ImageDraw.Draw(hl)
    half = int(bw * 0.5)
    for y in range(half):
        hd.line([(0, y), (bw, y)], fill=int(34 * (1 - y / half) ** 2))
    hl = Image.composite(hl, Image.new("L", (bw, bw), 0), m)
    hi = Image.new("RGBA", (bw, bw), (255, 255, 255, 0))
    hi.putalpha(hl)
    layer2 = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    layer2.paste(hi, (inset, inset))
    canvas.alpha_composite(layer2)
    return canvas


def glyph_triage_ring(canvas, S):
    """A · 判断环：三段圆环，比例取自真实的 2335 / 6758 / 425，内径比 0.618。"""
    c = S / 2
    outer = f(296, S)
    inner = outer * 0.618
    d = ImageDraw.Draw(canvas)
    segs = [(2335, GREEN), (6758, GRAY), (425, ORANGE)]
    total = sum(v for v, _ in segs)
    ang = -90.0
    gap = 3.4
    for v, col in segs:
        sweep = 360.0 * v / total
        d.pieslice([c - outer, c - outer, c + outer, c + outer],
                   ang + gap / 2, ang + sweep - gap / 2, fill=col + (255,))
        ang += sweep
    d.ellipse([c - inner, c - inner, c + inner, c + inner], fill=(0, 0, 0, 0))
    r = f(60, S)
    d.ellipse([c - r, c - r, c + r, c + r], fill=WHITE + (255,))


def glyph_converge(canvas, S):
    """B · 收束：四条不等长的横线，向右收成一个圆点。"""
    d = ImageDraw.Draw(canvas)
    right = S / 2 + f(120, S)
    widths = [320, 252, 184, 112]
    h = f(46, S)
    gap = f(34, S)
    block = len(widths) * h + (len(widths) - 1) * gap
    top = S / 2 - block / 2
    for i, w in enumerate(widths):
        y = top + i * (h + gap)
        d.rounded_rectangle([right - f(w, S), y, right, y + h],
                            radius=h / 2, fill=WHITE + (255,))
    r = f(50, S)
    px = right + f(74, S)
    d.ellipse([px - r, S / 2 - r, px + r, S / 2 + r], fill=GREEN + (255,))


def glyph_vault_docs(canvas, S):
    """C · 文件库：三张叠起来的文档，最上面一张有绿色折角。"""
    d = ImageDraw.Draw(canvas)
    cx = cy = S / 2
    w, h = f(300, S), f(380, S)
    r = f(44, S)
    for dx, dy, alpha in [(-f(56, S), f(30, S), 78), (-f(28, S), f(15, S), 140)]:
        d.rounded_rectangle([cx - w / 2 + dx, cy - h / 2 + dy,
                             cx + w / 2 + dx, cy + h / 2 + dy],
                            radius=r, fill=WHITE + (int(alpha),))
    d.rounded_rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2],
                        radius=r, fill=WHITE + (255,))
    fold = f(120, S)
    d.polygon([(cx + w / 2 - fold, cy - h / 2), (cx + w / 2, cy - h / 2),
               (cx + w / 2, cy - h / 2 + fold)], fill=GREEN + (255,))


GLYPHS = {"A": ("判断环", glyph_triage_ring),
          "B": ("收束", glyph_converge),
          "C": ("文件库", glyph_vault_docs)}
PALETTE_OF = {"A": "ink", "B": "ink", "C": "slate"}


def render(key, size):
    ss = SS_MAX if size <= 256 else 2
    S = size * ss
    canvas = base(PALETTE_OF[key], S)
    GLYPHS[key][1](canvas, S)
    return canvas.resize((size, size), Image.LANCZOS)


def build_sheet():
    keys = ["A", "B", "C"]
    sizes = [256, 128, 64, 32, 16]
    pad, label_w, gap, rowh = 30, 190, 28, 300
    W = label_w + sum(s + gap for s in sizes) + pad
    H = rowh * len(keys) + pad
    sheet = Image.new("RGB", (W, H), (245, 245, 247))
    d = ImageDraw.Draw(sheet)
    font = safe_font(30)
    for r, k in enumerate(keys):
        y = pad + r * rowh
        d.text((pad, y + rowh // 2 - 22), f"{k} - {GLYPHS[k][0]}",
               fill=(30, 30, 30), font=font)
        x = label_w
        for s in sizes:
            img = render(k, s)
            sheet.paste(img, (x, y + (rowh - pad - s) // 2), img)
            x += s + gap
    sheet.save(PREVIEW)
    return PREVIEW


def export_icns(key):
    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    for pt, scale in specs:
        px = pt * scale
        suffix = "" if scale == 1 else "@2x"
        render(key, px).save(os.path.join(iconset, f"icon_{pt}x{pt}{suffix}.png"))
    render(key, 1024).save(os.path.join(OUT, "AppIcon-1024.png"))
    print(f"  OK {len(specs)} sizes -> icon/AppIcon.iconset/")
    print("  OK 1024 -> icon/AppIcon-1024.png")
    return iconset


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    if "--pick" in sys.argv:
        export_icns(sys.argv[sys.argv.index("--pick") + 1].upper())
    else:
        for k in GLYPHS:
            render(k, 1024).save(os.path.join(OUT, f"cand-{k}-1024.png"))
        print("  sheet ->", build_sheet())


# ══════════════════════════════════════════════════════════════════════
# 第二轮候选：第一轮 A/B/C 在 32px 以下都糊了。
# 教训 —— 16px 只能读轮廓，所以要「一个粗形状 + 高对比 + ≤2 色」。
# ══════════════════════════════════════════════════════════════════════

def glyph_pie(canvas, S):
    """D · 饼：实心圆切三块。比圆环好读 —— 小尺寸下是一整块mass，不是一个圈。"""
    c = S / 2
    r = f(300, S)
    d = ImageDraw.Draw(canvas)
    segs = [(2335, GREEN), (6758, (96, 99, 122)), (425, ORANGE)]
    total = sum(v for v, _ in segs)
    ang = -90.0
    for v, col in segs:
        sweep = 360.0 * v / total
        d.pieslice([c - r, c - r, c + r, c + r], ang, ang + sweep - 2.0,
                   fill=col + (255,))
        ang += sweep


def glyph_thick_ring(canvas, S):
    """E · 粗环：内径 0.45（不是 0.618），两段。去掉中心白点和灰，避免像活动圆环。"""
    c = S / 2
    outer = f(312, S)
    inner = outer * 0.45
    d = ImageDraw.Draw(canvas)
    d.ellipse([c - outer, c - outer, c + outer, c + outer], fill=GREEN + (255,))
    d.pieslice([c - outer, c - outer, c + outer, c + outer], -90, 78,
               fill=(96, 99, 122, 255))
    d.pieslice([c - outer, c - outer, c + outer, c + outer], 84, 100,
               fill=ORANGE + (255,))
    d.ellipse([c - inner, c - inner, c + inner, c + inner], fill=(0, 0, 0, 0))


def glyph_three_bars(canvas, S):
    """F · 三条粗横条，长度递减。第一轮 B 是 4 条细线，32px 就糊；3 条粗的能活。"""
    d = ImageDraw.Draw(canvas)
    widths = [420, 300, 180]
    h = f(84, S)
    gap = f(56, S)
    block = len(widths) * h + (len(widths) - 1) * gap
    top = S / 2 - block / 2
    left = S / 2 - f(210, S)
    cols = [WHITE, WHITE, GREEN]
    for i, w in enumerate(widths):
        y = top + i * (h + gap)
        d.rounded_rectangle([left, y, left + f(w, S), y + h],
                            radius=h / 2, fill=cols[i] + (255,))


def glyph_scan_frame(canvas, S):
    """G · 扫描框：四个直角 + 中心实心点。轮廓极强，16px 也认得出是个「取景」。"""
    d = ImageDraw.Draw(canvas)
    half = f(268, S)
    arm = f(120, S)
    lw = f(56, S)
    c = S / 2
    for sx, sy in [(-1, -1), (1, -1), (-1, 1), (1, 1)]:
        x, y = c + sx * half, c + sy * half
        d.rounded_rectangle([min(x, x - sx * arm), y - lw / 2,
                             max(x, x - sx * arm), y + lw / 2],
                            radius=lw / 2, fill=WHITE + (255,))
        d.rounded_rectangle([x - lw / 2, min(y, y - sy * arm),
                             x + lw / 2, max(y, y - sy * arm)],
                            radius=lw / 2, fill=WHITE + (255,))
    r = f(86, S)
    d.ellipse([c - r, c - r, c + r, c + r], fill=GREEN + (255,))


def glyph_page_fold(canvas, S):
    """H · 一张纸，右下角被切掉一块。轮廓是一个「不完整的方块」，有辨识度。"""
    d = ImageDraw.Draw(canvas)
    w, h = f(392, S), f(452, S)
    r = f(52, S)
    x0, y0 = S / 2 - w / 2, S / 2 - h / 2
    x1, y1 = x0 + w, y0 + h
    cut = f(168, S)
    d.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=WHITE + (255,))
    d.polygon([(x1 - cut, y1 + 4), (x1 + 4, y1 - cut), (x1 + 4, y1 + 4)],
              fill=(0, 0, 0, 0))
    d.polygon([(x1 - cut, y1), (x1, y1 - cut), (x1, y1)], fill=GREEN + (255,))


def glyph_stack_plus_dot(canvas, S):
    """I · 三条粗横线（文件）右侧一个实心绿点，线比 B 粗一倍。"""
    d = ImageDraw.Draw(canvas)
    right = S / 2 + f(88, S)
    widths = [368, 288, 208]
    h = f(74, S)
    gap = f(52, S)
    block = len(widths) * h + (len(widths) - 1) * gap
    top = S / 2 - block / 2
    for i, w in enumerate(widths):
        y = top + i * (h + gap)
        d.rounded_rectangle([right - f(w, S), y, right, y + h],
                            radius=h / 2, fill=WHITE + (255,))
    r = f(78, S)
    px = right + f(108, S)
    d.ellipse([px - r, S / 2 - r, px + r, S / 2 + r], fill=GREEN + (255,))


ROUND2 = {"D": ("饼", glyph_pie, "ink"),
          "E": ("粗环", glyph_thick_ring, "ink"),
          "F": ("三条粗横条", glyph_three_bars, "ink"),
          "G": ("扫描框", glyph_scan_frame, "ink"),
          "H": ("缺角纸", glyph_page_fold, "slate"),
          "I": ("粗线收束", glyph_stack_plus_dot, "ink")}


def build_sheet2():
    keys = list(ROUND2)
    sizes = [128, 64, 32, 16]
    pad, label_w, gap, rowh = 28, 200, 26, 190
    W = label_w + sum(s + gap for s in sizes) + pad
    H = (rowh + pad) * len(keys) + pad
    sheet = Image.new("RGB", (W, H), (245, 245, 247))
    d = ImageDraw.Draw(sheet)
    font = safe_font(28)
    for r, k in enumerate(keys):
        y = pad + r * (rowh + pad)
        d.text((pad, y + rowh // 2 - 20), f"{k} - {ROUND2[k][0]}",
               fill=(30, 30, 30), font=font)
        x = label_w
        for s in sizes:
            ss = 4 if s <= 256 else 2
            S2 = s * ss
            cv = base(ROUND2[k][2], S2)
            ROUND2[k][1](cv, S2)
            img = cv.resize((s, s), Image.LANCZOS)
            sheet.paste(img, (x, y + (rowh - s) // 2), img)
            x += s + gap
    p = os.path.join(OUT, "_candidates2.png")
    sheet.save(p)
    return p


def export_pick2(key):
    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    for pt, scale in specs:
        px = pt * scale
        ss = 4 if px <= 256 else 2
        S2 = px * ss
        cv = base(ROUND2[key][2], S2)
        ROUND2[key][1](cv, S2)
        sfx = "" if scale == 1 else "@2x"
        cv.resize((px, px), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{pt}x{pt}{sfx}.png"))
    ss = 2
    cv = base(ROUND2[key][2], 1024 * ss)
    ROUND2[key][1](cv, 1024 * ss)
    cv.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "AppIcon-1024.png"))
    print("  OK -> icon/AppIcon.iconset/ + AppIcon-1024.png")


# ══════════════════════════════════════════════════════════════════════
# 第三轮：朝「一整块实心 mass + 高对比」收敛。
# 16px 下能活下来的只有大块实心形状，细线一律糊掉。
# ══════════════════════════════════════════════════════════════════════

def glyph_scan_bold(canvas, S):
    """J · 扫描框（加粗版）：角更短更粗，中心点更大。修 16px 下点会消失的问题。"""
    d = ImageDraw.Draw(canvas)
    half = f(252, S)
    arm = f(104, S)
    lw = f(76, S)
    c = S / 2
    for sx, sy in [(-1, -1), (1, -1), (-1, 1), (1, 1)]:
        x, y = c + sx * half, c + sy * half
        d.rounded_rectangle([min(x, x - sx * arm), y - lw / 2,
                             max(x, x - sx * arm), y + lw / 2],
                            radius=lw / 2, fill=WHITE + (255,))
        d.rounded_rectangle([x - lw / 2, min(y, y - sy * arm),
                             x + lw / 2, max(y, y - sy * arm)],
                            radius=lw / 2, fill=WHITE + (255,))
    r = f(116, S)
    d.ellipse([c - r, c - r, c + r, c + r], fill=GREEN + (255,))


def glyph_tag(canvas, S):
    """K · 标签：带孔的圆角方，45° 摆放。实心 mass，16px 也认得出。"""
    W = f(560, S)
    c = S / 2
    sq = Image.new("RGBA", (int(W), int(W)), (0, 0, 0, 0))
    dd = ImageDraw.Draw(sq)
    dd.rounded_rectangle([0, 0, W - 1, W - 1], radius=f(96, S), fill=WHITE + (255,))
    # 孔
    hr = f(74, S)
    hx, hy = f(150, S), f(150, S)
    dd.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=(0, 0, 0, 0))
    sq = sq.rotate(45, resample=Image.BICUBIC, expand=False)
    canvas.alpha_composite(sq, (int(c - W / 2), int(c - W / 2)))
    # 孔里放绿点，暗示"扫到了"
    d = ImageDraw.Draw(canvas)
    r = f(44, S)
    d.ellipse([c - r, c - r, c + r, c + r], fill=GREEN + (255,))


def glyph_viewfinder(canvas, S):
    """L · 取景孔：一整块实心圆角方，中间挖个圆，圆心里一个绿点。"""
    d = ImageDraw.Draw(canvas)
    w = f(600, S)
    c = S / 2
    d.rounded_rectangle([c - w / 2, c - w / 2, c + w / 2, c + w / 2],
                        radius=f(140, S), fill=WHITE + (255,))
    r = f(176, S)
    d.ellipse([c - r, c - r, c + r, c + r], fill=(0, 0, 0, 0))
    r2 = f(112, S)
    d.ellipse([c - r2, c - r2, c + r2, c + r2], fill=GREEN + (255,))


ROUND3 = {"J": ("扫描框加粗", glyph_scan_bold, "ink"),
          "K": ("标签", glyph_tag, "ink"),
          "L": ("取景孔", glyph_viewfinder, "slate")}


def build_sheet3():
    keys = list(ROUND3)
    sizes = [256, 128, 64, 32, 16]
    pad, label_w, gap, rowh = 30, 210, 28, 300
    W = label_w + sum(s + gap for s in sizes) + pad
    H = (rowh + pad) * len(keys) + pad
    sheet = Image.new("RGB", (W, H), (245, 245, 247))
    d = ImageDraw.Draw(sheet)
    font = safe_font(30)
    for r, k in enumerate(keys):
        y = pad + r * (rowh + pad)
        d.text((pad, y + rowh // 2 - 20), f"{k} - {ROUND3[k][0]}",
               fill=(30, 30, 30), font=font)
        x = label_w
        for s in sizes:
            ss = 4 if s <= 256 else 2
            S2 = s * ss
            cv = base(ROUND3[k][2], S2)
            ROUND3[k][1](cv, S2)
            img = cv.resize((s, s), Image.LANCZOS)
            sheet.paste(img, (x, y + (rowh - pad - s) // 2), img)
            x += s + gap
    p = os.path.join(OUT, "_candidates3.png")
    sheet.save(p)
    return p


def export_pick3(key):
    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for pt, scale in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)]:
        px = pt * scale
        ss = 4 if px <= 256 else 2
        S2 = px * ss
        cv = base(ROUND3[key][2], S2)
        ROUND3[key][1](cv, S2)
        sfx = "" if scale == 1 else "@2x"
        cv.resize((px, px), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{pt}x{pt}{sfx}.png"))
    S2 = 2048
    cv = base(ROUND3[key][2], S2)
    ROUND3[key][1](cv, S2)
    cv.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "AppIcon-1024.png"))
    print("  OK -> icon/AppIcon.iconset/ + AppIcon-1024.png")


# ══════════════════════════════════════════════════════════════════════
# 第四轮（定稿轮）
# 前几轮的结论：能同时满足「有意义」和「16px 活着」的只有——
#   一整块实心 + 两三个高对比色块。
# 所以：饼（实心，无孔），第二段不用闷灰而用**面板本身的深藏青**，
# 对比度立刻上来，且和 icon 底色是同一族颜色。
# ══════════════════════════════════════════════════════════════════════

NAVY = (34, 36, 60)          # 面板深色，作为"没用"那一段


def glyph_pie_bold(canvas, S):
    """M · 实心饼：亮绿 + 深藏青 + 橙。无孔 —— 小尺寸下是一整块 mass。"""
    c = S / 2
    r = f(312, S)
    d = ImageDraw.Draw(canvas)
    segs = [(2335, GREEN), (6758, NAVY), (425, ORANGE)]
    total = sum(v for v, _ in segs)
    ang = -90.0
    for v, col in segs:
        sweep = 360.0 * v / total
        d.pieslice([c - r, c - r, c + r, c + r], ang, ang + sweep - 2.2,
                   fill=col + (255,))
        ang += sweep


def glyph_pie_ring(canvas, S):
    """N · M 加一个小圆孔：保留 app 里那个圆环的记忆，孔小到 16px 也还在。"""
    glyph_pie_bold(canvas, S)
    c = S / 2
    r = f(96, S)
    ImageDraw.Draw(canvas).ellipse([c - r, c - r, c + r, c + r],
                                   fill=(0, 0, 0, 0))


def glyph_page_big_fold(canvas, S):
    """O · 白纸 + 大折角：H 的改良，折角放大到 16px 也是一个可辨的点。"""
    d = ImageDraw.Draw(canvas)
    w, h = f(400, S), f(468, S)
    r = f(56, S)
    c = S / 2
    x0, y0 = c - w / 2, c - h / 2
    x1, y1 = x0 + w, y0 + h
    fold = f(196, S)
    d.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=WHITE + (255,))
    d.polygon([(x1 - fold, y0 - 4), (x1 + 4, y0 - 4), (x1 + 4, y0 + fold - 4)],
              fill=(0, 0, 0, 0))
    d.polygon([(x1 - fold, y0), (x1, y0), (x1, y0 + fold)], fill=GREEN + (255,))


ROUND4 = {"M": ("实心饼", glyph_pie_bold, "ink"),
          "N": ("饼带小孔", glyph_pie_ring, "ink"),
          "O": ("白纸大折角", glyph_page_big_fold, "slate")}


def build_sheet4():
    keys = list(ROUND4)
    sizes = [512, 256, 128, 64, 32, 16]
    pad, label_w, gap, rowh = 30, 210, 26, 560
    W = label_w + sum(s + gap for s in sizes) + pad
    H = (rowh + pad) * len(keys) + pad
    sheet = Image.new("RGB", (W, H), (245, 245, 247))
    d = ImageDraw.Draw(sheet)
    font = safe_font(30)
    for r, k in enumerate(keys):
        y = pad + r * (rowh + pad)
        d.text((pad, y + rowh // 2 - 20), f"{k} - {ROUND4[k][0]}",
               fill=(30, 30, 30), font=font)
        x = label_w
        for s in sizes:
            ss = 4 if s <= 256 else 2
            S2 = s * ss
            cv = base(ROUND4[k][2], S2)
            ROUND4[k][1](cv, S2)
            img = cv.resize((s, s), Image.LANCZOS)
            sheet.paste(img, (x, y + (rowh - pad - s) // 2), img)
            x += s + gap
    p = os.path.join(OUT, "_candidates4.png")
    sheet.save(p)
    return p


def export_pick4(key):
    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for pt, scale in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)]:
        px = pt * scale
        ss = 4 if px <= 256 else 2
        S2 = px * ss
        cv = base(ROUND4[key][2], S2)
        ROUND4[key][1](cv, S2)
        sfx = "" if scale == 1 else "@2x"
        cv.resize((px, px), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{pt}x{pt}{sfx}.png"))
    cv = base(ROUND4[key][2], 2048)
    ROUND4[key][1](cv, 2048)
    cv.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "AppIcon-1024.png"))
    print("  OK -> icon/AppIcon.iconset/ + AppIcon-1024.png")


# ══════════════════════════════════════════════════════════════════════
# 第五轮（定稿对比）：P = 修好的判断环  vs  O = 白纸大折角
# 第四轮的教训：第二段的颜色**不能太贴近背景**，否则形状轮廓消失。
# 所以第二段取一个明确亮于底色的石板蓝，而不是面板深藏青。
# ══════════════════════════════════════════════════════════════════════

SLATE_RING = (116, 121, 152)


def glyph_ring_final(canvas, S):
    """
    P · 判断环（定稿版）
    改动三处，都是为了修第一版 A 的毛病：
      1. 去掉中心白点 —— 白点让整体读成「仪表盘」
      2. 环加粗（内径比 0.618 → 0.50）—— 16px 下太细就没了
      3. 灰色换成明确亮于底色的石板蓝 —— 原来的灰和深底对比不足
    """
    c = S / 2
    outer = f(304, S)
    inner = outer * 0.50
    d = ImageDraw.Draw(canvas)
    segs = [(2335, GREEN), (6758, SLATE_RING), (425, ORANGE)]
    total = sum(v for v, _ in segs)
    ang = -90.0
    gap = 3.6
    for v, col in segs:
        sweep = 360.0 * v / total
        d.pieslice([c - outer, c - outer, c + outer, c + outer],
                   ang + gap / 2, ang + sweep - gap / 2, fill=col + (255,))
        ang += sweep
    d.ellipse([c - inner, c - inner, c + inner, c + inner], fill=(0, 0, 0, 0))


ROUND5 = {"P": ("判断环定稿", glyph_ring_final, "ink"),
          "O": ("白纸大折角", glyph_page_big_fold, "slate")}


def build_sheet5():
    keys = ["P", "O"]
    sizes = [512, 256, 128, 64, 32, 16]
    pad, label_w, gap, rowh = 30, 210, 26, 560
    W = label_w + sum(s + gap for s in sizes) + pad
    H = (rowh + pad) * len(keys) + pad
    sheet = Image.new("RGB", (W, H), (245, 245, 247))
    d = ImageDraw.Draw(sheet)
    font = safe_font(30)
    for r, k in enumerate(keys):
        y = pad + r * (rowh + pad)
        d.text((pad, y + rowh // 2 - 20), f"{k} - {ROUND5[k][0]}",
               fill=(30, 30, 30), font=font)
        x = label_w
        for s in sizes:
            ss = 4 if s <= 256 else 2
            S2 = s * ss
            cv = base(ROUND5[k][2], S2)
            ROUND5[k][1](cv, S2)
            img = cv.resize((s, s), Image.LANCZOS)
            sheet.paste(img, (x, y + (rowh - pad - s) // 2), img)
            x += s + gap
    p = os.path.join(OUT, "_candidates5.png")
    sheet.save(p)
    return p


def export_pick5(key):
    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for pt, scale in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)]:
        px = pt * scale
        ss = 4 if px <= 256 else 2
        S2 = px * ss
        cv = base(ROUND5[key][2], S2)
        ROUND5[key][1](cv, S2)
        sfx = "" if scale == 1 else "@2x"
        cv.resize((px, px), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{pt}x{pt}{sfx}.png"))
    cv = base(ROUND5[key][2], 2048)
    ROUND5[key][1](cv, 2048)
    cv.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "AppIcon-1024.png"))
    print("  OK -> icon/AppIcon.iconset/ + AppIcon-1024.png")
