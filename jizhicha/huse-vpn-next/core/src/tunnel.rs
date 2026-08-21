//! Windows layer-3 forwarding for the Gateway NC tunnel.

use crate::error::{HuseVpnError, Result};
use crate::nc::{build_nc_data_frame, parse_nc_data_frames, NcAuthReply};
use crate::tls::RawTlsClient;
use std::collections::BTreeSet;
use std::net::Ipv4Addr;
use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::Command;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::oneshot;

const TUN_NAME: &str = "CampusVPN";
const CREATE_NO_WINDOW: u32 = 0x08000000;

fn hidden_command(program: &str) -> Command {
    let mut command = Command::new(program);
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

/// Forward raw IP packets between a Wintun interface and an already
/// authenticated NC/TLS connection. Gateway-provided non-default campus
/// routes plus the required host routes are installed into the adapter. A
/// default route is never accepted, so the existing Internet/VPN path remains
/// untouched.
pub async fn run_target_tunnel(
    tls: RawTlsClient,
    auth: &NcAuthReply,
    targets: &[Ipv4Addr],
    wintun_dll: impl AsRef<Path>,
    gateway_route: GatewayRoute,
) -> Result<()> {
    run_target_tunnel_inner(tls, auth, targets, wintun_dll, gateway_route, None).await
}

/// Start the target-scoped tunnel and report when both the Wintun adapter and
/// the /32 route are ready. This lets callers avoid reporting a connection
/// before local packet forwarding can actually begin.
pub async fn run_target_tunnel_with_ready(
    tls: RawTlsClient,
    auth: &NcAuthReply,
    targets: &[Ipv4Addr],
    wintun_dll: impl AsRef<Path>,
    gateway_route: GatewayRoute,
    ready: oneshot::Sender<std::result::Result<(), String>>,
) -> Result<()> {
    run_target_tunnel_inner(tls, auth, targets, wintun_dll, gateway_route, Some(ready)).await
}

async fn run_target_tunnel_inner(
    tls: RawTlsClient,
    auth: &NcAuthReply,
    targets: &[Ipv4Addr],
    wintun_dll: impl AsRef<Path>,
    _gateway_route: GatewayRoute,
    ready: Option<oneshot::Sender<std::result::Result<(), String>>>,
) -> Result<()> {
    let setup: Result<_> = (|| {
        if targets.is_empty() {
            return Err(HuseVpnError::Tunnel(
                "at least one target route is required".into(),
            ));
        }
        let virtual_ip: Ipv4Addr = auth.virtual_ip.parse().map_err(|e| {
            HuseVpnError::Tunnel(format!(
                "gateway returned an invalid virtual IPv4 address: {e}"
            ))
        })?;

        let mut configuration = tun2::Configuration::default();
        configuration
            .tun_name(TUN_NAME)
            .address(virtual_ip)
            .netmask(Ipv4Addr::new(255, 255, 255, 255))
            .up();
        configuration.platform_config(|platform| {
            platform.wintun_file(wintun_dll.as_ref().as_os_str());
        });

        let device = tun2::create_as_async(&configuration)
            .map_err(|e| HuseVpnError::Tunnel(format!("failed to create Wintun adapter: {e}")))?;
        let prefixes = campus_route_prefixes(auth, targets);
        let interface_index = tunnel_interface_index()?;
        let mut routes = Vec::with_capacity(prefixes.len());
        for prefix in prefixes {
            routes.push(TargetRoute::install(prefix, interface_index)?);
        }
        let (tun_writer, tun_reader) = device
            .split()
            .map_err(|e| HuseVpnError::Tunnel(format!("failed to split Wintun adapter: {e}")))?;
        Ok((tun_writer, tun_reader, routes))
    })();

    let (mut tun_writer, mut tun_reader, _routes) = match setup {
        Ok(value) => {
            if let Some(ready) = ready {
                let _ = ready.send(Ok(()));
            }
            value
        }
        Err(error) => {
            if let Some(ready) = ready {
                let _ = ready.send(Err(error.to_string()));
            }
            return Err(error);
        }
    };
    let virtual_ip: Ipv4Addr = auth.virtual_ip.parse().map_err(|e| {
        HuseVpnError::Tunnel(format!(
            "gateway returned an invalid virtual IPv4 address: {e}"
        ))
    })?;
    let (mut tls_reader, mut tls_writer) = tls.into_split();

    let uplink = async {
        let mut packet = vec![0u8; u16::MAX as usize];
        let mut packet_count = 0u64;
        loop {
            let length = tun_reader
                .read(&mut packet)
                .await
                .map_err(|e| HuseVpnError::Tunnel(format!("Wintun read failed: {e}")))?;
            if length == 0 {
                return Err(HuseVpnError::Tunnel("Wintun reader closed".into()));
            }
            validate_ip_packet(&packet[..length])?;
            let frame = build_nc_data_frame(&packet[..length])?;
            packet_count += 1;
            if packet_count <= 24 || packet_count % 100 == 0 {
                eprintln!(
                    "HUSE VPN uplink packet: count={}, ip_len={}, nc_frame_len={}, {}",
                    packet_count,
                    length,
                    frame.len(),
                    packet_summary(&packet[..length], virtual_ip)
                );
            }
            tls_writer.write(&frame).await?;
        }
    };

    let downlink = async {
        loop {
            let record = tls_reader.read_record().await?;
            eprintln!("HUSE VPN downlink TLS plaintext: len={}", record.len());
            for packet in parse_nc_data_frames(&record)? {
                validate_ip_packet(&packet)?;
                tun_writer
                    .write_all(&packet)
                    .await
                    .map_err(|e| HuseVpnError::Tunnel(format!("Wintun write failed: {e}")))?;
            }
        }
    };

    tokio::select! {
        result = uplink => {
            if let Err(error) = &result {
                eprintln!("HUSE VPN uplink stopped: {error}");
            }
            result
        },
        result = downlink => {
            if let Err(error) = &result {
                eprintln!("HUSE VPN downlink stopped: {error}");
            }
            result
        },
    }
}

/// A route to the Gateway itself on the physical interface. It prevents the
/// NC control/data socket from being captured by another VPN or by the
/// CampusVPN adapter being created here.
#[derive(Debug)]
pub struct GatewayRoute {
    prefix: String,
    interface_index: u32,
    next_hop: Ipv4Addr,
    installed: bool,
}

impl GatewayRoute {
    pub fn install(gateway: Ipv4Addr) -> Result<Self> {
        let (interface_index, next_hop) = physical_default_route()?;
        let prefix = format!("{gateway}/32");

        if let Some((existing_interface, existing_next_hop)) = existing_gateway_route(&prefix) {
            if existing_interface != interface_index || existing_next_hop != next_hop {
                return Err(HuseVpnError::Tunnel(
                    "Gateway route already exists on a different interface".into(),
                ));
            }
            return Ok(Self {
                prefix,
                interface_index,
                next_hop,
                installed: false,
            });
        }

        let output = hidden_command("netsh")
            .args([
                "interface",
                "ipv4",
                "add",
                "route",
                &format!("prefix={prefix}"),
                &format!("interface={interface_index}"),
                &format!("nexthop={next_hop}"),
                "metric=1",
                "store=active",
            ])
            .output()
            .map_err(|e| HuseVpnError::Tunnel(format!("failed to add Gateway route: {e}")))?;
        if !output.status.success() {
            let detail = if output.stderr.is_empty() {
                String::from_utf8_lossy(&output.stdout).trim().to_string()
            } else {
                String::from_utf8_lossy(&output.stderr).trim().to_string()
            };
            return Err(HuseVpnError::Tunnel(format!(
                "failed to add Gateway route: {detail}"
            )));
        }
        Ok(Self {
            prefix,
            interface_index,
            next_hop,
            installed: true,
        })
    }
}

impl Drop for GatewayRoute {
    fn drop(&mut self) {
        if !self.installed {
            return;
        }
        let _ = hidden_command("netsh")
            .args([
                "interface",
                "ipv4",
                "delete",
                "route",
                &format!("prefix={}", self.prefix),
                &format!("interface={}", self.interface_index),
                &format!("nexthop={}", self.next_hop),
                "store=active",
            ])
            .output();
    }
}

fn physical_default_route() -> Result<(u32, Ipv4Addr)> {
    let script = r#"
$route = $null
for ($attempt = 0; $attempt -lt 5 -and $null -eq $route; $attempt++) {
  $candidates = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' -and $_.NextHop -notlike '198.18.*' }

  # Prefer a live physical adapter. FlClash (198.18.*) and other overlay
  # adapters can also install a default route, but they must not carry the
  # Gateway control connection that is established before the tunnel.
  $route = $candidates |
    ForEach-Object {
      $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
      if ($adapter -and $adapter.Status -eq 'Up' -and $adapter.HardwareInterface -eq $true) {
        $_
      }
    } |
    Sort-Object RouteMetric,InterfaceMetric | Select-Object -First 1

  # Some Windows builds do not expose HardwareInterface for every physical
  # NIC. If that property is unavailable, retain the safe next-hop filter as
  # a fallback instead of failing the whole connection.
  if ($null -eq $route) {
    $route = $candidates | Sort-Object RouteMetric,InterfaceMetric | Select-Object -First 1
  }
  if ($null -eq $route -and $attempt -lt 4) {
    Start-Sleep -Milliseconds 200
  }
}
if ($route) { '{0}|{1}' -f $route.InterfaceIndex,$route.NextHop }
"#;
    let output = hidden_command("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .output()
        .map_err(|e| {
            HuseVpnError::Tunnel(format!("failed to inspect physical Gateway route: {e}"))
        })?;
    let value = String::from_utf8_lossy(&output.stdout);
    let (interface, next_hop) = value.trim().split_once('|').ok_or_else(|| {
        HuseVpnError::Tunnel("no physical IPv4 default route is available for the Gateway".into())
    })?;
    let interface_index = interface.trim().parse::<u32>().map_err(|_| {
        HuseVpnError::Tunnel("physical Gateway route has an invalid interface".into())
    })?;
    let next_hop = next_hop.trim().parse::<Ipv4Addr>().map_err(|_| {
        HuseVpnError::Tunnel("physical Gateway route has an invalid next hop".into())
    })?;
    Ok((interface_index, next_hop))
}

fn existing_gateway_route(prefix: &str) -> Option<(u32, Ipv4Addr)> {
    let script = format!(
        "Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '{prefix}' | Select-Object -First 1 | ForEach-Object {{ '{{0}}|{{1}}' -f $_.InterfaceIndex,$_.NextHop }}"
    );
    let output = hidden_command("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .ok()?;
    let value = String::from_utf8_lossy(&output.stdout);
    let (interface, next_hop) = value.trim().split_once('|')?;
    Some((
        interface.trim().parse().ok()?,
        next_hop.trim().parse().ok()?,
    ))
}

fn validate_ip_packet(packet: &[u8]) -> Result<()> {
    if packet.is_empty() || !matches!(packet[0] >> 4, 4 | 6) {
        return Err(HuseVpnError::Protocol(
            "NC data payload is not an IPv4 or IPv6 packet".into(),
        ));
    }
    Ok(())
}

fn packet_summary(packet: &[u8], virtual_ip: Ipv4Addr) -> String {
    if packet.len() < 20 || packet[0] >> 4 != 4 {
        return format!(
            "ip_version={}",
            packet.first().map(|byte| byte >> 4).unwrap_or(0)
        );
    }

    let source = Ipv4Addr::new(packet[12], packet[13], packet[14], packet[15]);
    let destination = Ipv4Addr::new(packet[16], packet[17], packet[18], packet[19]);
    let destination_class = match destination.octets() {
        [172, 20, 63, 226] => "jw",
        [222, 243, 204, 25] => "library",
        [172, 19, 0, 192] | [172, 19, 0, 200] => "campus",
        _ => "other",
    };
    format!(
        "ipv4_src={}, dst={}, ipv4_src_virtual={}, dst_class={}, proto={}",
        source,
        destination,
        source == virtual_ip,
        destination_class,
        packet[9]
    )
}

fn campus_route_prefixes(auth: &NcAuthReply, required: &[Ipv4Addr]) -> Vec<String> {
    let mut prefixes = BTreeSet::new();
    for route in &auth.profile_routes {
        let address = route.address.parse::<Ipv4Addr>();
        let mask = route.netmask.parse::<Ipv4Addr>();
        if let (Ok(address), Ok(mask)) = (address, mask) {
            if let Some(prefix) = network_prefix(address, mask) {
                prefixes.insert(prefix);
            }
        }
    }
    for address in required {
        prefixes.insert(format!("{address}/32"));
    }
    prefixes.into_iter().collect()
}

fn network_prefix(address: Ipv4Addr, mask: Ipv4Addr) -> Option<String> {
    let mask = u32::from(mask);
    let prefix_length = mask.leading_ones();
    if prefix_length == 0 {
        return None;
    }
    let expected = u32::MAX.checked_shl(32 - prefix_length).unwrap_or(0);
    if mask != expected {
        return None;
    }
    let network = u32::from(address) & mask;
    Some(format!("{}/{}", Ipv4Addr::from(network), prefix_length))
}

struct TargetRoute {
    prefix: String,
    interface_index: u32,
    installed: bool,
}

impl TargetRoute {
    fn install(prefix: String, interface_index: u32) -> Result<Self> {
        // A previous native session may have left an active route behind while
        // its Wintun handle was being torn down.  Reuse it, and do not delete
        // someone else's route when this session ends.
        if route_exists(&prefix, interface_index) {
            return Ok(Self {
                prefix,
                interface_index,
                installed: false,
            });
        }
        let output = hidden_command("netsh")
            .args([
                "interface",
                "ipv4",
                "add",
                "route",
                &format!("prefix={prefix}"),
                &format!("interface={interface_index}"),
                "nexthop=0.0.0.0",
                "metric=1",
                "store=active",
            ])
            .output()
            .map_err(|e| HuseVpnError::Tunnel(format!("failed to add target route: {e}")))?;
        if !output.status.success() {
            let detail = if output.stderr.is_empty() {
                String::from_utf8_lossy(&output.stdout).trim().to_string()
            } else {
                String::from_utf8_lossy(&output.stderr).trim().to_string()
            };
            return Err(HuseVpnError::Tunnel(format!(
                "failed to add target route: {detail}"
            )));
        }
        // Windows updates the active route table asynchronously.  Give it a
        // short grace period before declaring the tunnel unusable; this also
        // catches a non-elevated netsh invocation deterministically.
        let mut installed = false;
        for attempt in 0..10 {
            if route_exists(&prefix, interface_index) {
                installed = true;
                break;
            }
            if attempt < 9 {
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
        if !installed {
            return Err(HuseVpnError::Tunnel(format!(
                "target route {prefix} was not installed on CampusVPN (interface {interface_index})"
            )));
        }
        Ok(Self {
            prefix,
            interface_index,
            installed: true,
        })
    }
}

impl Drop for TargetRoute {
    fn drop(&mut self) {
        if !self.installed {
            return;
        }
        let _ = hidden_command("netsh")
            .args([
                "interface",
                "ipv4",
                "delete",
                "route",
                &format!("prefix={}", self.prefix),
                &format!("interface={}", self.interface_index),
                "nexthop=0.0.0.0",
                "store=active",
            ])
            .output();
    }
}

/// Resolve the Wintun interface by alias once and use its numeric index for
/// every netsh operation.  `interface=CampusVPN` is accepted by some builds
/// of netsh but is treated as an invalid interface on others, which leaves
/// the adapter up without any target routes.
fn tunnel_interface_index() -> Result<u32> {
    let script = format!(
        "Get-NetAdapter -Name '{}' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InterfaceIndex",
        TUN_NAME.replace('\'', "''")
    );
    let mut last_error = None;
    for attempt in 0..20 {
        let output = hidden_command("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", &script])
            .output()
            .map_err(|e| {
                HuseVpnError::Tunnel(format!("failed to inspect CampusVPN interface: {e}"))
            })?;
        if output.status.success() {
            let value = String::from_utf8_lossy(&output.stdout);
            if let Ok(index) = value.trim().parse::<u32>() {
                return Ok(index);
            }
        }
        last_error = Some(String::from_utf8_lossy(&output.stderr).trim().to_string());
        if attempt < 19 {
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
    }
    let detail = last_error.filter(|value| !value.is_empty());
    Err(HuseVpnError::Tunnel(match detail {
        Some(detail) => format!("CampusVPN interface index is unavailable: {detail}"),
        None => "CampusVPN interface index is unavailable".into(),
    }))
}

fn route_exists(prefix: &str, interface_index: u32) -> bool {
    let script = format!(
        "Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '{}' -InterfaceIndex {} -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object {{ 'ok' }}",
        prefix.replace('\'', "''"),
        interface_index
    );
    hidden_command("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .map(|output| {
            output.status.success() && !String::from_utf8_lossy(&output.stdout).trim().is_empty()
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_ip_versions() {
        assert!(validate_ip_packet(&[0x45]).is_ok());
        assert!(validate_ip_packet(&[0x60]).is_ok());
        assert!(validate_ip_packet(&[]).is_err());
        assert!(validate_ip_packet(&[0x10]).is_err());
    }

    #[test]
    fn converts_contiguous_masks_and_rejects_default_or_broken_masks() {
        assert_eq!(
            network_prefix(
                Ipv4Addr::new(172, 19, 4, 99),
                Ipv4Addr::new(255, 255, 255, 0)
            ),
            Some("172.19.4.0/24".into())
        );
        assert_eq!(
            network_prefix(Ipv4Addr::new(1, 2, 3, 4), Ipv4Addr::UNSPECIFIED),
            None
        );
        assert_eq!(
            network_prefix(Ipv4Addr::new(172, 19, 0, 0), Ipv4Addr::new(255, 0, 255, 0)),
            None
        );
    }
}
