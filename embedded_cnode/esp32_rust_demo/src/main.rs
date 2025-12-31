//! ESP32 Erlang C-Node Demo
//!
//! Demonstrates an ESP32 device communicating with an Erlang node using the
//! Erlang distribution protocol. This example performs a 10-round ping-pong
//! exchange with random integers to verify bidirectional communication.
//!
//! Uses OpenCores Ethernet for QEMU networking.

use esp_idf_hal::prelude::*;
use esp_idf_svc::eventloop::EspSystemEventLoop;
use esp_idf_svc::eth::{EspEth, EthDriver, OpenEth};
use esp_idf_svc::netif::{EspNetif, NetifConfiguration};
use esp_idf_svc::ipv4::{ClientConfiguration, Configuration};
use esp_idf_sys as _;

use erlang_node::{CNode, Term};
use log::*;
use std::time::Duration;

// Erlang node connection info
// 10.0.2.2 is the host from QEMU's user-mode networking perspective
const ERLANG_HOST: &str = "10.0.2.2";
const ERLANG_PORT: u16 = 9000;
const COOKIE: &str = "testcookie";

fn main() -> anyhow::Result<()> {
    // Initialize ESP-IDF
    esp_idf_sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();

    info!("ESP32 Rust Erlang Node starting...");

    // Initialize peripherals
    let peripherals = Peripherals::take()?;
    let sysloop = EspSystemEventLoop::take()?;

    info!("Initializing OpenCores Ethernet for QEMU...");

    // Create OpenCores Ethernet driver (for QEMU)
    let eth_driver = EthDriver::<OpenEth>::new(peripherals.mac, sysloop.clone())?;

    // Use DHCP - QEMU provides DHCP at 10.0.2.2
    let ip_config = Configuration::Client(ClientConfiguration::DHCP(Default::default()));

    let netif_config = NetifConfiguration {
        ip_configuration: Some(ip_config),
        ..NetifConfiguration::eth_default_client()
    };

    // Create network interface
    let mut eth = EspEth::wrap_all(eth_driver, EspNetif::new_with_conf(&netif_config)?)?;

    info!("Ethernet interface created, starting...");

    // Start ethernet
    eth.start()?;

    info!("Ethernet started, waiting for link and DHCP...");

    // Wait for network to be ready
    for i in 0..30 {
        std::thread::sleep(Duration::from_millis(500));

        // Check if we have link and IP
        if let Ok(ip_info) = eth.netif().get_ip_info() {
            if ip_info.ip.octets() != [0, 0, 0, 0] {
                info!("Got IP address: {:?}", ip_info);
                break;
            }
        }
        info!("Waiting for network... ({}/30)", i + 1);
    }

    // Get IP info
    match eth.netif().get_ip_info() {
        Ok(ip_info) => {
            info!("Network ready! IP: {:?}, Gateway: {:?}", ip_info.ip, ip_info.subnet.gateway);
        }
        Err(e) => {
            error!("Failed to get IP info: {:?}", e);
        }
    }

    info!("Attempting to connect to Erlang node at {}:{}", ERLANG_HOST, ERLANG_PORT);

    // Create our C-node
    let mut node = CNode::new("esp32", "esp32host", COOKIE);
    info!("Created node: {}", node.node_name());

    // Try to connect
    match node.connect(ERLANG_HOST, ERLANG_PORT) {
        Ok(()) => {
            info!("Successfully connected to Erlang node!");

            // Simple pseudo-random number generator using system time
            let mut seed = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos() as u32)
                .unwrap_or(12345);

            let mut success_count = 0;

            // Do 10 ping-pong rounds
            for round in 1..=10 {
                // Generate random number (simple LCG)
                seed = seed.wrapping_mul(1103515245).wrapping_add(12345);
                let random_num = (seed >> 16) & 0x7FFF;

                // Get our PID for this message
                let self_pid = node.self_pid();

                // Send ping with random number: {ping, Number, Pid}
                let ping_msg = Term::tuple(vec![
                    Term::atom("ping"),
                    Term::Integer(random_num as i64),
                    Term::Pid(self_pid.clone()),
                ]);

                info!("[Round {}] Sending: {{ping, {}}}", round, random_num);
                match node.reg_send("esp_handler", ping_msg) {
                    Ok(()) => {}
                    Err(e) => {
                        error!("[Round {}] Failed to send ping: {}", round, e);
                        continue;
                    }
                }

                // Wait for pong response, skipping system messages
                let mut found_pong = false;
                for _attempt in 0..10 {
                    match node.receive() {
                        Ok(msg) => {
                            if let Some(payload) = msg.payload {
                                // Check if this is a pong message
                                if let Term::Tuple(ref elements) = payload {
                                    if elements.len() >= 2 {
                                        if let Term::Atom(ref atom) = elements[0] {
                                            if atom == "pong" {
                                                // This is our pong!
                                                if let Term::Integer(n) = elements[1] {
                                                    if n == random_num as i64 {
                                                        info!("[Round {}] Received: {{pong, {}}} - OK!", round, n);
                                                        success_count += 1;
                                                    } else {
                                                        error!("[Round {}] Number mismatch! Sent {} got {}", round, random_num, n);
                                                    }
                                                }
                                                found_pong = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                                // Skip non-pong messages (system messages from distribution protocol)
                                info!("[Round {}] Skipping system message", round);
                            }
                        }
                        Err(e) => {
                            error!("[Round {}] Failed to receive: {}", round, e);
                            break;
                        }
                    }
                }
                if !found_pong {
                    error!("[Round {}] Did not receive pong", round);
                }
            }

            info!("Ping-pong complete: {}/10 successful rounds", success_count);

            node.disconnect();
            info!("Disconnected.");
        }
        Err(e) => {
            error!("Failed to connect to Erlang node: {}", e);
        }
    }

    info!("ESP32 Erlang node demo complete.");

    // Keep eth alive and program running
    loop {
        std::thread::sleep(Duration::from_secs(10));
    }
}
