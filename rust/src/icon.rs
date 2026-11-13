//! The tray dial and the application icon, drawn in code.

use std::fs;
use std::io;
use std::path::Path;

use rayon::prelude::*;

pub type Rgba = [u8; 4];

pub const ICON_SIZE: usize = 32;

/// Amber reads on both light and dark trays.
pub const ICON_COLOR: Rgba = [224, 122, 63, 255];

/// The colour the tray dial is drawn in. On macOS the icon is a template: only its alpha
/// counts, and the system recolours it for a light or dark menu bar.
pub fn tray_color() -> Rgba {
    if cfg!(target_os = "macos") {
        [255, 255, 255, 255]
    } else {
        ICON_COLOR
    }
}

/// Angle of a point measured from 12 o'clock, going clockwise, in 0..2π.
fn dial_angle(dx: f64, dy: f64) -> f64 {
    let angle = dx.atan2(-dy);
    if angle < 0.0 {
        angle + std::f64::consts::TAU
    } else {
        angle
    }
}

/// Renders a dial filled in proportion to usage, as RGBA pixels. On Windows and Linux this
/// is the only carrier of information in the tray — unlike the macOS menu bar, there is no
/// text next to the icon.
pub fn draw_icon(percent: f64, color: Rgba) -> Vec<u8> {
    let center = ICON_SIZE as f64 / 2.0;
    let radius = center - 1.5;
    let frac = (percent / 100.0).clamp(0.0, 1.0);
    let dim = [color[0], color[1], color[2], 70];

    let mut pixels = vec![0u8; ICON_SIZE * ICON_SIZE * 4];
    for (i, pixel) in pixels.chunks_exact_mut(4).enumerate() {
        let (x, y) = (i % ICON_SIZE, i / ICON_SIZE);
        let (dx, dy) = (x as f64 + 0.5 - center, y as f64 + 0.5 - center);
        let dist = dx.hypot(dy);
        if dist > radius {
            continue;
        }
        // The rim stays solid so the icon reads even at 0%.
        let filled = dist > radius - 2.5 || dial_angle(dx, dy) <= frac * std::f64::consts::TAU;
        pixel.copy_from_slice(if filled { &color } else { &dim });
    }
    pixels
}

pub fn encode_png(rgba: &[u8], width: usize, height: usize) -> Vec<u8> {
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width as u32, height as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    // Writing into a Vec cannot fail, and the buffer always matches the header.
    let mut writer = encoder.write_header().expect("PNG header");
    writer.write_image_data(rgba).expect("PNG data");
    drop(writer);
    out
}

/// Reads the dimensions out of a PNG's IHDR chunk.
pub fn png_size(png: &[u8]) -> Option<(u32, u32)> {
    const SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
    if png.len() < 24 || !png.starts_with(SIGNATURE) || &png[12..16] != b"IHDR" {
        return None;
    }
    let be = |at: usize| u32::from_be_bytes([png[at], png[at + 1], png[at + 2], png[at + 3]]);
    Some((be(16), be(20)))
}

/// Wraps one or more PNGs in an ICO container, which is what the .exe icon resource
/// requires. PNG inside ICO is valid from Vista onwards.
pub fn to_ico(pngs: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend(0u16.to_le_bytes()); // reserved
    out.extend(1u16.to_le_bytes()); // type: icon
    out.extend((pngs.len() as u16).to_le_bytes());
    let mut offset = 6 + 16 * pngs.len();

    for png in pngs {
        let Some((width, height)) = png_size(png) else { continue };
        // A dimension of 256 is stored as 0 — that is what the ICO spec says, and what the
        // conversion to a byte produces anyway.
        out.push(width as u8);
        out.push(height as u8);
        out.push(0); // no palette
        out.push(0); // reserved
        out.extend(1u16.to_le_bytes()); // planes
        out.extend(32u16.to_le_bytes()); // bits per pixel
        out.extend((png.len() as u32).to_le_bytes());
        out.extend((offset as u32).to_le_bytes());
        offset += png.len();
    }
    for png in pngs {
        out.extend_from_slice(png);
    }
    out
}

// ─── Application icon (Dock, Explorer, launcher) ──────────────────────────────

// Claude's coral on the backdrop, a white gauge on top. The tray icon is minimal out of
// necessity; this one has to stay recognisable in a Dock or an application list.
const BRAND_BG: [f64; 3] = [217.0, 119.0, 87.0];
const WHITE: [f64; 3] = [255.0, 255.0, 255.0];

/// Mixes two opaque colours: t=1 yields pure fg, t=0 pure bg. Channels are truncated to
/// whole values, as they would be when stored.
fn blend(fg: [f64; 3], bg: [f64; 3], t: f64) -> [f64; 3] {
    [0, 1, 2].map(|i| (fg[i] * t + bg[i] * (1.0 - t)).floor())
}

/// Draws a rounded square holding a usage gauge, as RGBA pixels. Sampling 3×3 per pixel
/// smooths the edges — without it the arc and the corners look ragged at small sizes.
/// Rows are independent, so they are rendered in parallel.
pub fn app_icon_rgba(size: usize) -> Vec<u8> {
    let s = size as f64;
    let radius = s * 0.225; // corner radius
    let center = s / 2.0;
    let ring_outer = s * 0.32;
    let ring_inner = s * 0.225;
    const GAUGE_FRAC: f64 = 0.68; // decorative fill level for the static icon
    const SAMPLES: usize = 9;

    let in_rounded_rect = |x: f64, y: f64| {
        let dx = (radius - x).max(x - (s - radius)).max(0.0);
        let dy = (radius - y).max(y - (s - radius)).max(0.0);
        dx.hypot(dy) <= radius
    };
    // Every subsample is opaque — the translucent arc is blended with the backdrop right
    // here. That way alpha carries pixel coverage only, and averaging the colour is a
    // plain mean.
    let sample = |x: f64, y: f64| {
        let dist = (x - center).hypot(y - center);
        if dist > ring_outer {
            return BRAND_BG;
        }
        if dist >= ring_inner {
            if dial_angle(x - center, y - center) <= GAUGE_FRAC * std::f64::consts::TAU {
                return WHITE;
            }
            return blend(WHITE, BRAND_BG, 0.35); // unfilled part of the ring
        }
        if dist <= ring_inner * 0.42 {
            return WHITE; // centre dot
        }
        BRAND_BG
    };

    let mut pixels = vec![0u8; size * size * 4];
    pixels.par_chunks_mut(size * 4).enumerate().for_each(|(py, row)| {
        for (px, pixel) in row.chunks_exact_mut(4).enumerate() {
            let mut sum = [0.0f64; 3];
            let mut covered = 0usize;
            for sy in 0..3 {
                for sx in 0..3 {
                    let x = px as f64 + (sx as f64 + 0.5) / 3.0;
                    let y = py as f64 + (sy as f64 + 0.5) / 3.0;
                    if !in_rounded_rect(x, y) {
                        continue;
                    }
                    let c = sample(x, y);
                    for i in 0..3 {
                        sum[i] += c[i];
                    }
                    covered += 1;
                }
            }
            if covered == 0 {
                continue;
            }
            let n = covered as f64;
            pixel.copy_from_slice(&[
                (sum[0] / n) as u8,
                (sum[1] / n) as u8,
                (sum[2] / n) as u8,
                (covered * 255 / SAMPLES) as u8,
            ]);
        }
    });
    pixels
}

pub fn app_icon(size: usize) -> Vec<u8> {
    encode_png(&app_icon_rgba(size), size, size)
}

/// Generates the full icon set (PNGs at several sizes plus an ICO) into a folder.
pub fn write_icons(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    const SIZES: [usize; 8] = [16, 32, 48, 64, 128, 256, 512, 1024];
    let pngs: Vec<Vec<u8>> = SIZES.par_iter().map(|&size| app_icon(size)).collect();
    for (size, png) in SIZES.iter().zip(&pngs) {
        fs::write(dir.join(format!("icon_{size}.png")), png)?;
    }
    let by_size = |size: usize| pngs[SIZES.iter().position(|&s| s == size).unwrap()].as_slice();
    fs::write(dir.join("icon.png"), by_size(512))?;
    // ICO does not accept dimensions above 256.
    let ico = to_ico(&[16, 32, 48, 64, 128, 256].map(by_size));
    fs::write(dir.join("icon.ico"), ico)
}
