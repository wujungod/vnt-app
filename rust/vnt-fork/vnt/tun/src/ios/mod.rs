//! iOS TUN Device Implementation
//! 
//! This module provides a stub implementation for iOS TUN devices.
//! On iOS, TUN devices must be created through the Network Extension framework,
//! and the file descriptor is passed from Swift/Objective-C code.
//!
//! Usage:
//! 1. In your iOS Network Extension, create a NEPacketTunnelProvider
//! 2. Get the file descriptor using getTunnelFileDescriptor()
//! 3. Pass the fd to Rust via FFI
//! 4. Use Device::from_fd(fd) to create the device

mod device;
pub use device::Device;
