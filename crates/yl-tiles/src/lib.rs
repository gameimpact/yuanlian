//! Dirty-tile screen update engine.
//!
//! The screen is split into a fixed grid. Each update hashes every tile,
//! encodes only tiles whose pixels changed, and later re-encodes changed
//! tiles once at a higher quality after the screen has been stable for a
//! short period ("static refinement"). This is the basis of the
//! balanced/flow modes; it is not a video codec and does not depend on
//! Moonlight/Sunshine.

use std::time::{Duration, Instant};

use anyhow::{bail, Result};
use blake3::Hasher;
use image::{codecs::jpeg::JpegEncoder, ExtendedColorType, RgbaImage};

pub const DEFAULT_TILE_SIZE: u32 = 128;
pub const DEFAULT_QUALITY: u8 = 85;
pub const DEFAULT_REFINE_QUALITY: u8 = 95;
pub const DEFAULT_REFINE_DELAY: Duration = Duration::from_millis(600);
const MAX_DIMENSION: u32 = 16_384;
const MAX_TILES: usize = 8_192;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TileRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

impl TileRect {
    pub fn new(x: u32, y: u32, width: u32, height: u32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedTile {
    pub rect: TileRect,
    pub jpeg: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct FrameUpdate {
    pub generation: u32,
    pub full: bool,
    pub width: u32,
    pub height: u32,
    pub tiles: Vec<EncodedTile>,
}

impl FrameUpdate {
    pub fn encoded_bytes(&self) -> usize {
        self.tiles.iter().map(|t| t.jpeg.len()).sum()
    }
}

#[derive(Debug, Clone)]
pub struct TileSettings {
    pub tile_size: u32,
    pub quality: u8,
    pub refine_quality: u8,
    pub refine_delay: Duration,
}

impl Default for TileSettings {
    fn default() -> Self {
        Self {
            tile_size: DEFAULT_TILE_SIZE,
            quality: DEFAULT_QUALITY,
            refine_quality: DEFAULT_REFINE_QUALITY,
            refine_delay: DEFAULT_REFINE_DELAY,
        }
    }
}

pub struct TileDiffer {
    settings: TileSettings,
    width: u32,
    height: u32,
    generation: u32,
    hashes: Vec<Option<blake3::Hash>>,
    last_change: Vec<Instant>,
    refined: Vec<bool>,
}

impl TileDiffer {
    pub fn new(width: u32, height: u32, settings: TileSettings) -> Result<Self> {
        validate_geometry(width, height, settings.tile_size)?;
        let count = tile_count(width, height, settings.tile_size)?;
        Ok(Self {
            settings,
            width,
            height,
            generation: 1,
            hashes: vec![None; count],
            last_change: vec![Instant::now(); count],
            refined: vec![false; count],
        })
    }

    pub fn generation(&self) -> u32 {
        self.generation
    }

    pub fn geometry(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    pub fn settings(&self) -> &TileSettings {
        &self.settings
    }

    /// Clears all caches. Callers must send a full frame next; the generation
    /// also changes so viewers discard stale tiles.
    pub fn invalidate(&mut self) {
        self.generation = self.generation.wrapping_add(1).max(1);
        self.hashes.fill(None);
        self.refined.fill(false);
        let now = Instant::now();
        self.last_change.fill(now);
    }

    /// Returns `None` when nothing changed and no refinement is due.
    pub fn update(&mut self, image: &RgbaImage, force_full: bool) -> Result<Option<FrameUpdate>> {
        let (width, height) = image.dimensions();
        let geometry_changed = width != self.width || height != self.height;
        if geometry_changed {
            validate_geometry(width, height, self.settings.tile_size)?;
            let count = tile_count(width, height, self.settings.tile_size)?;
            self.width = width;
            self.height = height;
            self.generation = self.generation.wrapping_add(1).max(1);
            self.hashes = vec![None; count];
            self.last_change = vec![Instant::now(); count];
            self.refined = vec![false; count];
        }
        let force_full = force_full || geometry_changed;
        let now = Instant::now();
        let mut tiles = Vec::new();

        for y in (0..height).step_by(self.settings.tile_size as usize) {
            for x in (0..width).step_by(self.settings.tile_size as usize) {
                let rect = TileRect::new(
                    x,
                    y,
                    self.settings.tile_size.min(width - x),
                    self.settings.tile_size.min(height - y),
                );
                let index = self.index_of(rect.x, rect.y);
                let hash = hash_tile(image, rect);
                let changed = force_full || self.hashes[index] != Some(hash);

                if changed {
                    tiles.push(EncodedTile {
                        rect,
                        jpeg: encode_tile(image, rect, self.settings.quality)?,
                    });
                    self.hashes[index] = Some(hash);
                    self.last_change[index] = now;
                    self.refined[index] = false;
                } else if !self.refined[index]
                    && now.duration_since(self.last_change[index]) >= self.settings.refine_delay
                {
                    tiles.push(EncodedTile {
                        rect,
                        jpeg: encode_tile(image, rect, self.settings.refine_quality)?,
                    });
                    self.refined[index] = true;
                }
            }
        }

        if tiles.is_empty() {
            return Ok(None);
        }
        Ok(Some(FrameUpdate {
            generation: self.generation,
            full: force_full,
            width,
            height,
            tiles,
        }))
    }

    fn index_of(&self, x: u32, y: u32) -> usize {
        let tiles_per_row = self.width.div_ceil(self.settings.tile_size);
        let row = y / self.settings.tile_size;
        let col = x / self.settings.tile_size;
        (row * tiles_per_row + col) as usize
    }
}

fn validate_geometry(width: u32, height: u32, tile_size: u32) -> Result<()> {
    if width == 0 || height == 0 {
        bail!("screen dimensions must be non-zero");
    }
    if width > MAX_DIMENSION || height > MAX_DIMENSION {
        bail!("screen dimensions exceed {MAX_DIMENSION}: {width}x{height}");
    }
    if tile_size == 0 || tile_size > 1024 {
        bail!("tile size out of range: {tile_size}");
    }
    if tile_count(width, height, tile_size)? > MAX_TILES {
        bail!("too many tiles for {width}x{height} with tile size {tile_size}");
    }
    Ok(())
}

fn tile_count(width: u32, height: u32, tile_size: u32) -> Result<usize> {
    let cols = width.div_ceil(tile_size) as usize;
    let rows = height.div_ceil(tile_size) as usize;
    cols.checked_mul(rows)
        .filter(|n| *n > 0 && *n <= MAX_TILES)
        .ok_or_else(|| anyhow::anyhow!("invalid tile count"))
}

fn hash_tile(image: &RgbaImage, rect: TileRect) -> blake3::Hash {
    let raw = image.as_raw();
    let stride = image.width() as usize * 4;
    let mut hasher = Hasher::new();
    for row in rect.y..rect.y + rect.height {
        let start = row as usize * stride + rect.x as usize * 4;
        let end = start + rect.width as usize * 4;
        hasher.update(&raw[start..end]);
    }
    hasher.finalize()
}

fn encode_tile(image: &RgbaImage, rect: TileRect, quality: u8) -> Result<Vec<u8>> {
    let raw = image.as_raw();
    let stride = image.width() as usize * 4;
    let mut rgb = Vec::with_capacity((rect.width * rect.height * 3) as usize);
    for row in rect.y..rect.y + rect.height {
        let start = row as usize * stride + rect.x as usize * 4;
        let end = start + rect.width as usize * 4;
        for pixel in raw[start..end].as_chunks::<4>().0 {
            rgb.extend_from_slice(&pixel[..3]);
        }
    }
    let mut jpeg = Vec::new();
    let mut encoder = JpegEncoder::new_with_quality(&mut jpeg, quality.clamp(1, 100));
    encoder.encode(&rgb, rect.width, rect.height, ExtendedColorType::Rgb8)?;
    Ok(jpeg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    fn solid(width: u32, height: u32, color: [u8; 4]) -> RgbaImage {
        RgbaImage::from_pixel(width, height, Rgba(color))
    }

    fn settings(refine_delay: Duration) -> TileSettings {
        TileSettings {
            tile_size: 128,
            quality: 85,
            refine_quality: 95,
            refine_delay,
        }
    }

    #[test]
    fn first_frame_is_full_and_static_frame_is_empty() {
        let image = solid(300, 200, [10, 20, 30, 255]);
        let mut differ = TileDiffer::new(300, 200, settings(Duration::from_millis(600))).unwrap();
        let first = differ.update(&image, true).unwrap().unwrap();
        assert!(first.full);
        assert_eq!(first.tiles.len(), 6);
        assert!(differ.update(&image, false).unwrap().is_none());
    }

    #[test]
    fn only_changed_tile_is_sent() {
        let mut image = solid(300, 200, [10, 20, 30, 255]);
        let mut differ = TileDiffer::new(300, 200, settings(Duration::from_millis(600))).unwrap();
        differ.update(&image, true).unwrap().unwrap();
        image.put_pixel(5, 5, Rgba([255, 255, 255, 255]));
        let update = differ.update(&image, false).unwrap().unwrap();
        assert!(!update.full);
        assert_eq!(update.tiles.len(), 1);
        assert_eq!(update.tiles[0].rect, TileRect::new(0, 0, 128, 128));
    }

    #[test]
    fn static_refinement_runs_once() {
        let image = solid(200, 200, [1, 2, 3, 255]);
        let mut differ = TileDiffer::new(200, 200, settings(Duration::ZERO)).unwrap();
        differ.update(&image, true).unwrap().unwrap();
        let refine = differ.update(&image, false).unwrap().unwrap();
        assert_eq!(refine.tiles.len(), 4);
        assert!(differ.update(&image, false).unwrap().is_none());
    }

    #[test]
    fn geometry_change_increments_generation_and_forces_full() {
        let mut differ = TileDiffer::new(200, 200, settings(Duration::from_millis(600))).unwrap();
        let first = differ
            .update(&solid(200, 200, [0, 0, 0, 255]), true)
            .unwrap()
            .unwrap();
        let gen1 = first.generation;
        let second = differ
            .update(&solid(400, 300, [0, 0, 0, 255]), false)
            .unwrap()
            .unwrap();
        assert!(second.full);
        assert_eq!(second.generation, gen1 + 1);
        assert_eq!((second.width, second.height), (400, 300));
        assert_eq!(second.tiles.len(), 12);
    }

    #[test]
    fn rejects_absurd_geometry() {
        assert!(TileDiffer::new(0, 100, TileSettings::default()).is_err());
        assert!(TileDiffer::new(100_000, 100, TileSettings::default()).is_err());
    }
}
