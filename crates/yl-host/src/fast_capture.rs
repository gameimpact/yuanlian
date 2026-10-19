//! Persistent GDI screen capture for Windows.
//!
//! XCap creates DCs/bitmaps per call. This backend keeps one screen DC, one
//! compatible DC and one top-down 32-bit DIB alive for the session, then
//! BitBlt's the selected monitor region into it. It is still GDI, not
//! DXGI/WGC, but removes per-frame allocation/setup overhead and gives a
//! measurable path toward the balanced-mode frame budget.
//!
//! The BGRA→RGBA conversion is parallelized; the caller receives a normal
//! `RgbaImage` so the tile engine is unchanged.

use std::ffi::c_void;
use std::ptr;
use std::slice;

use anyhow::{bail, Context, Result};
use image::RgbaImage;
use rayon::prelude::*;

#[repr(C)]
struct BitmapInfoHeader {
    size: u32,
    width: i32,
    height: i32,
    planes: u16,
    bit_count: u16,
    compression: u32,
    size_image: u32,
    x_pels_per_meter: i32,
    y_pels_per_meter: i32,
    colors_used: u32,
    colors_important: u32,
}

#[repr(C)]
struct BitmapInfo {
    header: BitmapInfoHeader,
    colors: [u32; 1],
}

#[link(name = "user32")]
extern "system" {
    fn GetDC(hwnd: *mut c_void) -> *mut c_void;
    fn ReleaseDC(hwnd: *mut c_void, hdc: *mut c_void) -> i32;
}

#[link(name = "gdi32")]
extern "system" {
    fn CreateCompatibleDC(hdc: *mut c_void) -> *mut c_void;
    fn CreateDIBSection(
        hdc: *mut c_void,
        pbmi: *const BitmapInfo,
        usage: u32,
        bits: *mut *mut c_void,
        section: *mut c_void,
        offset: u32,
    ) -> *mut c_void;
    fn SelectObject(hdc: *mut c_void, object: *mut c_void) -> *mut c_void;
    fn BitBlt(
        dst: *mut c_void,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        src: *mut c_void,
        src_x: i32,
        src_y: i32,
        rop: u32,
    ) -> i32;
    fn DeleteObject(object: *mut c_void) -> i32;
    fn DeleteDC(hdc: *mut c_void) -> i32;
}

const SRCCOPY: u32 = 0x00CC_0020;
const DIB_RGB_COLORS: u32 = 0;
const BI_RGB: u32 = 0;

pub struct FastCapture {
    screen_dc: *mut c_void,
    memory_dc: *mut c_void,
    bitmap: *mut c_void,
    previous: *mut c_void,
    bits: *mut u8,
    width: u32,
    height: u32,
    origin_x: i32,
    origin_y: i32,
}

impl FastCapture {
    pub fn new(width: u32, height: u32, origin_x: i32, origin_y: i32) -> Result<Self> {
        if width == 0 || height == 0 || width > 16_384 || height > 16_384 {
            bail!("invalid capture geometry {width}x{height}");
        }
        let screen_dc = unsafe { GetDC(ptr::null_mut()) };
        if screen_dc.is_null() {
            bail!("GetDC(NULL) failed: {}", std::io::Error::last_os_error());
        }
        let memory_dc = unsafe { CreateCompatibleDC(screen_dc) };
        if memory_dc.is_null() {
            unsafe { ReleaseDC(ptr::null_mut(), screen_dc) };
            bail!(
                "CreateCompatibleDC failed: {}",
                std::io::Error::last_os_error()
            );
        }
        let mut info: BitmapInfo = unsafe { std::mem::zeroed() };
        info.header.size = std::mem::size_of::<BitmapInfoHeader>() as u32;
        info.header.width = width as i32;
        info.header.height = -(height as i32);
        info.header.planes = 1;
        info.header.bit_count = 32;
        info.header.compression = BI_RGB;
        let mut bits: *mut c_void = ptr::null_mut();
        let bitmap = unsafe {
            CreateDIBSection(
                memory_dc,
                &info,
                DIB_RGB_COLORS,
                &mut bits,
                ptr::null_mut(),
                0,
            )
        };
        if bitmap.is_null() || bits.is_null() {
            unsafe {
                DeleteDC(memory_dc);
                ReleaseDC(ptr::null_mut(), screen_dc);
            }
            bail!(
                "CreateDIBSection failed: {}",
                std::io::Error::last_os_error()
            );
        }
        let previous = unsafe { SelectObject(memory_dc, bitmap) };
        Ok(Self {
            screen_dc,
            memory_dc,
            bitmap,
            previous,
            bits: bits.cast::<u8>(),
            width,
            height,
            origin_x,
            origin_y,
        })
    }

    pub fn capture(&mut self) -> Result<RgbaImage> {
        let ok = unsafe {
            BitBlt(
                self.memory_dc,
                0,
                0,
                self.width as i32,
                self.height as i32,
                self.screen_dc,
                self.origin_x,
                self.origin_y,
                SRCCOPY,
            )
        };
        if ok == 0 {
            bail!("BitBlt failed: {}", std::io::Error::last_os_error());
        }
        let len = self.width as usize * self.height as usize * 4;
        let source = unsafe { slice::from_raw_parts(self.bits, len) };
        let mut pixels = vec![0u8; len];
        pixels
            .par_chunks_mut(4)
            .zip(source.par_chunks_exact(4))
            .for_each(|(destination, source)| {
                destination[0] = source[2];
                destination[1] = source[1];
                destination[2] = source[0];
                destination[3] = source[3];
            });
        RgbaImage::from_raw(self.width, self.height, pixels)
            .context("build RGBA image from GDI DIB")
    }
}

impl Drop for FastCapture {
    fn drop(&mut self) {
        unsafe {
            if !self.previous.is_null() {
                SelectObject(self.memory_dc, self.previous);
            }
            if !self.bitmap.is_null() {
                DeleteObject(self.bitmap);
            }
            if !self.memory_dc.is_null() {
                DeleteDC(self.memory_dc);
            }
            if !self.screen_dc.is_null() {
                ReleaseDC(ptr::null_mut(), self.screen_dc);
            }
        }
    }
}
