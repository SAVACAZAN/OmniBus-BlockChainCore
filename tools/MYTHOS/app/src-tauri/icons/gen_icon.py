from PIL import Image, ImageDraw, ImageFont
import math

SIZE = 256
CENTER = SIZE // 2
RADIUS = 110
RING_WIDTH = 10

# Base dark circle
img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

def hexagon_points(cx, cy, r, rotation=0):
    points = []
    for i in range(6):
        angle = math.radians(60 * i - 30 + rotation)
        points.append((cx + r * math.cos(angle), cy + r * math.sin(angle)))
    return points

def draw_gradient_ring(d, cx, cy, r, width, color1, color2, steps=120):
    for i in range(steps):
        angle1 = 2 * math.pi * i / steps
        angle2 = 2 * math.pi * (i + 1) / steps
        ratio = i / steps
        # Interpolate color
        c = tuple(int(color1[j] + (color2[j] - color1[j]) * ratio) for j in range(3))
        x1 = cx + (r - width/2) * math.cos(angle1)
        y1 = cy + (r - width/2) * math.sin(angle1)
        x2 = cx + (r + width/2) * math.cos(angle1)
        y2 = cy + (r + width/2) * math.sin(angle1)
        x3 = cx + (r + width/2) * math.cos(angle2)
        y3 = cy + (r + width/2) * math.sin(angle2)
        x4 = cx + (r - width/2) * math.cos(angle2)
        y4 = cy + (r - width/2) * math.sin(angle2)
        d.polygon([(x1,y1),(x2,y2),(x3,y3),(x4,y4)], fill=c)

# Background dark circle
for y in range(SIZE):
    for x in range(SIZE):
        dx, dy = x - CENTER, y - CENTER
        dist = math.sqrt(dx*dx + dy*dy)
        if dist <= RADIUS + 12:
            alpha = 255
            if dist > RADIUS:
                alpha = int(255 * max(0, 1 - (dist - RADIUS) / 12))
            img.putpixel((x, y), (10, 14, 23, alpha))

# Hexagon subtle
hex_r = RADIUS - 16
hex_points = hexagon_points(CENTER, CENTER, hex_r)
draw.line(hex_points + [hex_points[0]], fill=(139, 92, 246, 40), width=2)

# Inner hexagon (more subtle)
hex_points2 = hexagon_points(CENTER, CENTER, hex_r * 0.6)
draw.line(hex_points2 + [hex_points2[0]], fill=(6, 182, 212, 30), width=1)

# Gradient ring purple -> cyan
draw_gradient_ring(draw, CENTER, CENTER, RADIUS - 6, RING_WIDTH, (139, 92, 246), (6, 182, 212))

# Green arc for 97%
arc_radius = RADIUS - 22
arc_width = 6
arc_start = math.radians(-90)
arc_end = math.radians(-90 + 360 * 0.97)
steps = int(360 * 0.97 * 2)
for i in range(steps):
    angle = arc_start + (arc_end - arc_start) * i / steps
    x1 = CENTER + (arc_radius - arc_width/2) * math.cos(angle)
    y1 = CENTER + (arc_radius - arc_width/2) * math.sin(angle)
    x2 = CENTER + (arc_radius + arc_width/2) * math.cos(angle)
    y2 = CENTER + (arc_radius + arc_width/2) * math.sin(angle)
    draw.line([(x1,y1),(x2,y2)], fill=(16, 185, 129), width=2)

# 3 colored nodes on the ring
node_positions = [0.25, 0.55, 0.85]  # around the circle
node_colors = [(16, 185, 129), (139, 92, 246), (6, 182, 212)]
for pos, color in zip(node_positions, node_colors):
    angle = 2 * math.pi * pos - math.pi/2
    nx = CENTER + (RADIUS - 6) * math.cos(angle)
    ny = CENTER + (RADIUS - 6) * math.sin(angle)
    r = 7
    draw.ellipse([(nx-r, ny-r), (nx+r, ny+r)], fill=color)
    # glow
    for gr in range(r+1, r+4):
        alpha = int(80 * (1 - (gr - r) / 4))
        draw.ellipse([(nx-gr, ny-gr), (nx+gr, ny+gr)], fill=(*color, alpha))

# Letter M purple bold
try:
    font = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 100)
except:
    font = ImageFont.load_default()

text = "M"
bbox = draw.textbbox((0, 0), text, font=font)
tw = bbox[2] - bbox[0]
th = bbox[3] - bbox[1]
tx = CENTER - tw // 2
ty = CENTER - th // 2 - 8

# M glow
glow_color = (139, 92, 246)
for offset in [(0,0), (-1,-1), (1,1), (-1,1), (1,-1), (0,-2), (0,2), (-2,0), (2,0)]:
    draw.text((tx+offset[0], ty+offset[1]), text, font=font, fill=(*glow_color, 60))
draw.text((tx, ty), text, font=font, fill=(139, 92, 246, 255))

# Save outputs
base = r'C:\Kits work\limaje de programare\OmniBus aweb3 + OmniBus BlockChain\OmniBus-BlockChainCore\tools\MYTHOS\app\src-tauri\icons'

# Multi-size ICO
ico_sizes = [(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)]
ico_imgs = []
for w, h in ico_sizes:
    ico_imgs.append(img.resize((w,h), Image.LANCZOS))
ico_imgs[0].save(f'{base}\\icon.ico', format='ICO', sizes=ico_sizes)

# PNGs for tauri bundle
img.resize((32,32), Image.LANCZOS).save(f'{base}\\32x32.png')
img.resize((128,128), Image.LANCZOS).save(f'{base}\\128x128.png')
img.resize((256,256), Image.LANCZOS).save(f'{base}\\128x128@2x.png')
img.save(f'{base}\\icon.png')

# Simple icns placeholder (PNG renamed)
img.resize((512,512), Image.LANCZOS).save(f'{base}\\icon.icns')

print('Icons generated successfully!')
print(f'  ICO: {base}\\icon.ico (16,32,48,64,128,256)')
print(f'  PNG: 32x32, 128x128, 128x128@2x, icon.png')
