//! iOS TUN Device Stub Implementation
//!
//! On iOS, TUN devices must be created through the Network Extension framework.
//! This stub allows compilation but requires FFI integration for actual functionality.

use std::io;
use std::net::Ipv4Addr;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};

use crate::device::IFace;
use crate::unix::Fd;

/// A TUN device on iOS.
///
/// This is a stub implementation. On iOS, create the device using
/// `Device::from_fd(fd)` with a file descriptor obtained from
/// NEPacketTunnelProvider.
pub struct Device {
    name: String,
    fd: Option<Fd>,
}

impl Device {
    /// Create a new TUN device from a file descriptor.
    ///
    /// # Safety
    /// The file descriptor must be valid and open.
    pub unsafe fn from_raw_fd(fd: RawFd) -> io::Result<Self> {
        Ok(Device {
            name: format!("utun{}", fd),
            fd: Some(Fd::from_raw_fd(fd)),
        })
    }

    /// Create a new TUN device.
    ///
    /// On iOS, this returns an error because TUN devices can only be created
    /// through the Network Extension framework.
    pub fn new(_name: Option<String>) -> io::Result<Self> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "On iOS, TUN devices must be created from a file descriptor obtained via Network Extension. Use Device::from_raw_fd() instead.",
        ))
    }
}

impl IFace for Device {
    fn version(&self) -> io::Result<String> {
        Ok(String::from("iOS TUN Stub 1.0"))
    }

    fn name(&self) -> io::Result<String> {
        Ok(self.name.clone())
    }

    fn shutdown(&self) -> io::Result<()> {
        Ok(())
    }

    fn set_ip(&self, _address: Ipv4Addr, _mask: Ipv4Addr) -> io::Result<()> {
        // On iOS, this is handled by NEPacketTunnelNetworkSettings
        Ok(())
    }

    fn mtu(&self) -> io::Result<u32> {
        Ok(1500)
    }

    fn set_mtu(&self, _value: u32) -> io::Result<()> {
        Ok(())
    }

    fn add_route(&self, _dest: Ipv4Addr, _netmask: Ipv4Addr, _metric: u16) -> io::Result<()> {
        // On iOS, routes are configured through NEPacketTunnelNetworkSettings
        Ok(())
    }

    fn delete_route(&self, _dest: Ipv4Addr, _netmask: Ipv4Addr) -> io::Result<()> {
        Ok(())
    }

    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        if let Some(fd) = &self.fd {
            fd.read(buf)
        } else {
            Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "Device not initialized with file descriptor",
            ))
        }
    }

    fn write(&self, buf: &[u8]) -> io::Result<usize> {
        if let Some(fd) = &self.fd {
            // iOS utun expects a 4-byte header (protocol family)
            let mut packet = Vec::<u8>::with_capacity(4 + buf.len());
            packet.push(0);
            packet.push(0);
            packet.extend_from_slice(&(libc::PF_INET as u16).to_be_bytes());
            packet.extend_from_slice(buf);
            fd.write(&packet)
        } else {
            Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "Device not initialized with file descriptor",
            ))
        }
    }
}

impl AsRawFd for Device {
    fn as_raw_fd(&self) -> RawFd {
        self.fd.as_ref().map(|f| f.as_raw_fd()).unwrap_or(-1)
    }
}

/// Get a reference to the file descriptor
impl Device {
    pub fn as_tun_fd(&self) -> &Fd {
        static INVALID_FD: Fd = unsafe { Fd::from_raw_fd(-1) };
        self.fd.as_ref().unwrap_or(&INVALID_FD)
    }
}
