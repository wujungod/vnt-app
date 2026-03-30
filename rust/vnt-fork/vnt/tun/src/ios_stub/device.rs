use crate::device::IFace;
use crate::Fd;
use std::io;
use std::net::Ipv4Addr;
use std::os::fd::RawFd;

pub struct Device {
    fd: Fd,
}

impl Device {
    pub fn new(fd: RawFd) -> io::Result<Self> {
        Ok(Self { fd: Fd::new(fd)? })
    }
}
impl Device {
    pub fn as_tun_fd(&self) -> &Fd {
        &self.fd
    }
}
impl IFace for Device {
    fn version(&self) -> io::Result<String> {
        Ok(String::new())
    }

    fn name(&self) -> io::Result<String> {
        Ok(String::new())
    }

    fn shutdown(&self) -> io::Result<()> {
        Err(io::Error::from(io::ErrorKind::Unsupported))
    }

    fn set_ip(&self, _address: Ipv4Addr, _mask: Ipv4Addr) -> io::Result<()> {
        // On iOS, IP is configured through NEPacketTunnelNetworkSettings
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
        self.fd.read(buf)
    }

    fn write(&self, buf: &[u8]) -> io::Result<usize> {
        // iOS utun expects a 4-byte header (protocol family)
        let mut packet = Vec::<u8>::with_capacity(4 + buf.len());
        packet.push(0);
        packet.push(0);
        packet.extend_from_slice(&(libc::PF_INET as u16).to_be_bytes());
        packet.extend_from_slice(buf);
        self.fd.write(&packet)
    }
}
