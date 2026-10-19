//! Low-bandwidth dirty tiles: bounded latest-tile cache and a shared duplex budget.
use anyhow::Result;
use std::collections::{HashMap, VecDeque};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc,
};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, Mutex};
use yl_proto::{FrameMessage, ServerMessage, TileMessage};

// 800 kbit/s application + per-message overhead allowance. Leave 200 kbit/s
// for TLS/TCP/IP headers and ACKs. This is not a retransmission billing cap.
pub const BYTES_PER_SECOND: u64 = 100_000;
pub const FILE_SHARE_BYTES: u64 = 16_000;
pub const MAX_DATA_MESSAGE: usize = 12_288;

#[derive(Clone)]
pub struct Budget {
    next: Arc<Mutex<Instant>>,
    file_next: Arc<Mutex<Instant>>,
    rate: Arc<AtomicU64>,
}
impl Budget {
    pub fn new() -> Self {
        Self {
            next: Arc::new(Mutex::new(Instant::now())),
            file_next: Arc::new(Mutex::new(Instant::now())),
            rate: Arc::new(AtomicU64::new(BYTES_PER_SECOND)),
        }
    }
    pub fn charge_duration(bytes: usize, rate: u64) -> Duration {
        Duration::from_nanos(
            ((bytes as u128 * 1_000_000_000).div_ceil(rate as u128)).min(u64::MAX as u128) as u64,
        )
    }
    async fn reserve(lock: &Mutex<Instant>, bytes: usize, rate: u64) {
        let until = {
            let mut next = lock.lock().await;
            let now = Instant::now();
            let start = (*next).max(now);
            *next = start + Self::charge_duration(bytes, rate);
            *next
        };
        tokio::time::sleep_until(until.into()).await;
    }
    pub async fn charge(&self, bytes: usize, file: bool) {
        if file {
            Self::reserve(&self.file_next, bytes, self.file_rate()).await;
        }
        Self::reserve(
            &self.next,
            bytes.saturating_add(96),
            self.rate.load(Ordering::Relaxed),
        )
        .await;
    }
    fn file_rate(&self) -> u64 {
        FILE_SHARE_BYTES.min(self.rate.load(Ordering::Relaxed) / 5)
    }
    pub fn observe_write(&self, elapsed: Duration) {
        let rate = self.rate.load(Ordering::Relaxed);
        if elapsed > Duration::from_millis(150) {
            self.rate.store((rate / 2).max(8000), Ordering::Relaxed);
        } else if elapsed < Duration::from_millis(25) {
            self.rate
                .store((rate + 100).min(BYTES_PER_SECOND), Ordering::Relaxed);
        }
    }
    pub async fn try_file(&self, bytes: usize) -> bool {
        let mut next = self.file_next.lock().await;
        let now = Instant::now();
        if *next > now {
            return false;
        }
        *next = now + Self::charge_duration(bytes, self.file_rate());
        true
    }
}

pub fn capture_loop(
    monitor: usize,
    tx: mpsc::Sender<ServerMessage>,
    stop: Arc<AtomicBool>,
    force: Arc<AtomicBool>,
) -> Result<()> {
    let mut info = crate::capture::monitor_info(monitor)?;
    let settings = yl_tiles::TileSettings {
        tile_size: 64,
        quality: 40,
        refine_quality: 60,
        refine_delay: Duration::from_millis(1800),
    };
    let mut differ = yl_tiles::TileDiffer::new(info.width, info.height, settings)?;
    let mut pending = HashMap::new();
    let mut order = VecDeque::new();
    let mut last_capture = Instant::now() - Duration::from_secs(1);
    let mut first = true;
    let mut seq = 0;
    let mut generation = 1;
    let mut needs_full = false;
    while !stop.load(Ordering::Relaxed) {
        if last_capture.elapsed() >= Duration::from_millis(200) {
            let (_, image, _) = crate::capture::capture_once(monitor)?;
            let reset = force.swap(false, Ordering::Relaxed);
            if let Some(update) = differ.update(&image, reset)? {
                info.width = update.width;
                info.height = update.height;
                if reset || update.generation != generation {
                    pending.clear();
                    order.clear();
                    needs_full = true;
                }
                generation = update.generation;
                for tile in update.tiles {
                    let key = (tile.rect.x, tile.rect.y);
                    if !pending.contains_key(&key) {
                        order.push_back(key);
                    }
                    pending.insert(key, tile);
                }
            }
            last_capture = Instant::now();
        }
        // Reserve capacity before removing a tile: no lost deltas on pressure.
        if let Ok(slot) = tx.try_reserve() {
            if let Some(key) = order.pop_front() {
                if let Some(tile) = pending.remove(&key) {
                    seq += 1;
                    slot.send(ServerMessage::FlowFrame(FrameMessage {
                        seq,
                        screen_generation: generation,
                        full: first || needs_full,
                        width: info.width,
                        height: info.height,
                        tiles: vec![TileMessage {
                            x: tile.rect.x,
                            y: tile.rect.y,
                            width: tile.rect.width,
                            height: tile.rect.height,
                            jpeg: tile.jpeg,
                        }],
                    }));
                    first = false;
                    needs_full = false;
                }
            }
        }
        if tx.is_closed() {
            break;
        }
        std::thread::sleep(Duration::from_millis(4));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn budget_counts_framing_and_no_initial_burst() {
        assert_eq!(
            Budget::charge_duration(100_000, BYTES_PER_SECOND),
            Duration::from_secs(1)
        );
        assert!(Budget::charge_duration(8192, FILE_SHARE_BYTES) >= Duration::from_millis(512));
    }
    #[test]
    fn congestion_reduces_rate_and_recovery_cannot_exceed_ceiling() {
        let budget = Budget::new();
        budget.observe_write(Duration::from_millis(200));
        assert_eq!(budget.rate.load(Ordering::Relaxed), 50000);
        for _ in 0..20 {
            budget.observe_write(Duration::from_secs(1));
        }
        assert_eq!(budget.rate.load(Ordering::Relaxed), 8000);
        for _ in 0..2000 {
            budget.observe_write(Duration::ZERO);
        }
        assert_eq!(budget.rate.load(Ordering::Relaxed), BYTES_PER_SECOND);
    }
    #[tokio::test]
    async fn clones_share_duplex_budget() {
        let budget = Budget::new();
        let copy = budget.clone();
        let start = Instant::now();
        tokio::join!(budget.charge(10000, false), copy.charge(10000, false));
        assert!(start.elapsed() >= Duration::from_millis(200));
    }
}
