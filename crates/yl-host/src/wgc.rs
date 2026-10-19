//! Windows Graphics Capture producer.
//!
//! WGC delivers compositor frames without a per-frame GDI BitBlt. The handler
//! copies the RGBA frame (cursor excluded; the cursor has its own channel) and
//! sends it to a bounded channel consumed by the tile engine. If WGC cannot be
//! initialized, the caller falls back to the persistent GDI backend.

use std::error::Error;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::Arc;
use std::time::Duration;

use windows_capture::capture::{CaptureControl, Context, GraphicsCaptureApiHandler};
use windows_capture::frame::Frame;
use windows_capture::graphics_capture_api::InternalCaptureControl;
use windows_capture::monitor::Monitor;
use windows_capture::settings::{
    ColorFormat, CursorCaptureSettings, DirtyRegionSettings, DrawBorderSettings,
    MinimumUpdateIntervalSettings, SecondaryWindowSettings, Settings,
};

#[derive(Debug)]
pub struct CapturedFrame {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

pub struct Flags {
    tx: SyncSender<CapturedFrame>,
    stop: Arc<AtomicBool>,
}

pub struct Handler {
    flags: Flags,
}

pub type WgcError = Box<dyn Error + Send + Sync>;
pub type WgcControl = CaptureControl<Handler, WgcError>;

impl GraphicsCaptureApiHandler for Handler {
    type Flags = Flags;
    type Error = WgcError;

    fn new(ctx: Context<Self::Flags>) -> Result<Self, Self::Error> {
        Ok(Self { flags: ctx.flags })
    }

    fn on_frame_arrived(
        &mut self,
        frame: &mut Frame,
        capture_control: InternalCaptureControl,
    ) -> Result<(), Self::Error> {
        if self.flags.stop.load(Ordering::Relaxed) {
            capture_control.stop();
            return Ok(());
        }
        let width = frame.width();
        let height = frame.height();
        if width == 0 || height == 0 {
            return Ok(());
        }
        let buffer = frame.buffer()?;
        if buffer.color_format() != ColorFormat::Rgba8 {
            return Ok(());
        }
        let mut scratch = Vec::new();
        let pixels = buffer.as_nopadding_buffer(&mut scratch);
        let frame = CapturedFrame {
            width,
            height,
            pixels: pixels.to_vec(),
        };
        match self.flags.tx.try_send(frame) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) => {
                // The consumer is behind; dropping this new frame is safe
                // because the tile differ compares against the last processed
                // image and the next frame still carries the current content.
            }
            Err(TrySendError::Disconnected(_)) => {
                capture_control.stop();
            }
        }
        Ok(())
    }

    fn on_closed(&mut self) -> Result<(), Self::Error> {
        self.flags.stop.store(true, Ordering::Relaxed);
        Ok(())
    }
}

/// Starts a free-threaded WGC capture and returns a bounded frame receiver and
/// the control handle. The caller must stop the control when finished.
pub fn start(
    monitor_index: usize,
    fps: u32,
    stop: Arc<AtomicBool>,
) -> Result<(Receiver<CapturedFrame>, WgcControl), WgcError> {
    let monitor = Monitor::from_index(monitor_index)?;
    let (tx, rx) = sync_channel(2);
    let flags = Flags { tx, stop };
    let target = fps.clamp(1, 60);
    let update_interval = if target <= 30 {
        MinimumUpdateIntervalSettings::Custom(Duration::from_millis(25))
    } else {
        // Do not let the WGC-side throttle be the 60 fps ceiling; pacing is
        // verified from actual presented frames, not this request value.
        MinimumUpdateIntervalSettings::Default
    };
    let settings = Settings::new(
        monitor,
        CursorCaptureSettings::WithoutCursor,
        DrawBorderSettings::WithoutBorder,
        SecondaryWindowSettings::Default,
        update_interval,
        DirtyRegionSettings::Default,
        ColorFormat::Rgba8,
        flags,
    );
    let control = Handler::start_free_threaded(settings)?;
    Ok((rx, control))
}
