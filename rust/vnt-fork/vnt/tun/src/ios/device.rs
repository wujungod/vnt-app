//! iOS TUN Device Implementation
//!
//! This module provides TUN device support for iOS using file descriptors
//! obtained from Network Extension framework.

#![allow(dead_code)]

use std::io;
use std::net::Ipv4Addr;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};

use crate::device::IFace;
use crate::unix::Fd;

/// A TUN device on iOS.
///
/// On iOS, this device is created from a file descriptor obtained
/// through the Network Extension framework (NEPacketTunnelProvider).
pub struct Device {
    /// The TUN device name (usually utunX)
    name: String,
    /// The file descriptor for the TUN device
    tun: Fd,
    /// Whether the device has been configured
    configured: bool,
}

impl Device {
    /// Create a new TUN device from a file descriptor.
    ///
    /// The file descriptor should be obtained from the Network Extension
    /// using `getTunnelFileDescriptor()` or similar method.
    ///
    /// # Safety
    /// The file descriptor must be valid and open.
    pub unsafe fn from_fd(fd: RawFd) -> io::Result<Self> {
        let tun = Fd::from_raw_fd(fd);
        Ok(Device {
            name: format!("utun{}", fd),
            tun,
            configured: false,
        })
    }

    /// Create a new TUN device.
    ///
    /// On iOS, this will fail because TUN devices can only be created
    /// through the Network Extension framework. Use `from_fd()` instead.
    pub fn new(_name: Option<String>) -> io::Result<Self> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "On iOS, TUN devices must be created from a file descriptor obtained via Network Extension. Use Device::from_fd() instead.",
        ))
    }

    /// Set the device name (for internal use)
    pub fn set_name(&mut self, name: String) {
        self.name = name;
    }
}

impl IFace for Device {
    fn version(&self) -> io::Result<String> {
        Ok(String::from("iOS TUN 1.0"))
    }

    fn name(&self) -> io::Result<String> {
        Ok(self.name.clone())
    }

    fn shutdown(&self) -> io::Result<()> {
        // On iOS, the Network Extension manages the lifecycle
        Ok(())
    }

    fn set_ip(&self, _address: Ipv4Addr, _mask: Ipv4Addr) -> io::Result<()> {
        // On iOS, IP configuration is done through NEPacketTunnelNetworkSettings
        // in Swift/Objective-C code
        self.configured = true;
        Ok(())
    }

    fn mtu(&self) -> io::Result<u32> {
        // Default MTU for iOS
        Ok(1500)
    }

    fn set_mtu(&self, _value: u32) -> io::Result<()> {
        // On iOS, MTU is set through NEPacketTunnelNetworkSettings
        Ok(())
    }

    fn add_route(&self, _dest: Ipv4Addr, _netmask: Ipv4Addr, _metric: u16) -> io::Result<()> {
        // On iOS, routes are configured through NEPacketTunnelNetworkSettings
        Ok(())
    }

    fn delete_route(&self, _dest: Ipv4Addr, _netmask: Ipv4Addr) -> io::Result<()> {
        // On iOS, routes are managed by the Network Extension
        Ok(())
    }

    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        self.tun.read(buf)
    }

    fn write(&self, buf: &[u8]) -> io::Result<usize> {
        // iOS utun expects a 4-byte header (protocol family)
        let mut packet = Vec::<u8>::with_capacity(4 + buf.len());
        packet.push(0);
        packet.push(0);
        packet.extend_from_slice(&(libc::PF_INET as u16).to_be_bytes());
        packet.extend_from_slice(buf);
        self.tun.write(&packet)
    }
}

impl AsRawFd for Device {
    fn as_raw_fd(&self) -> RawFd {
        self.tun.as_raw_fd()
    }
}
