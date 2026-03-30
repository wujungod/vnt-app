/// 参考
/// https://github.com/meh/rust-tun
/// https://github.com/Tazdevil971/tap-windows
/// https://github.com/nulldotblack/wintun
pub mod device;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::Device;

#[cfg(target_os = "android")]
mod android;
#[cfg(target_os = "android")]
pub use android::Device;

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod macos;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use macos::Device;

#[cfg(target_os = "ios")]
mod ios;
#[cfg(target_os = "ios")]
pub use ios::Device;

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::Fd;
#[cfg(windows)]
mod windows;

#[cfg(windows)]
pub use windows::Device;

#[cfg(windows)]
mod packet;
