//! ESP32 Erlang C-Node Example
//!
//! Connects to an Erlang node and sends a message.

use esp_idf_hal::prelude::*;
use esp_idf_sys as _;

use erlang_node::{CNode, Term};
use log::*;

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
    let _peripherals = Peripherals::take()?;

    info!("Attempting to connect to Erlang node at {}:{}", ERLANG_HOST, ERLANG_PORT);

    // Create our C-node
    let mut node = CNode::new("esp32", "esp32host", COOKIE);
    info!("Created node: {}", node.node_name());

    // Try to connect
    match node.connect(ERLANG_HOST, ERLANG_PORT) {
        Ok(()) => {
            info!("Successfully connected to Erlang node!");

            // Get our PID
            let self_pid = node.self_pid();
            info!("Our PID: {:?}", self_pid);

            // Send a message
            let message = Term::tuple(vec![
                Term::atom("hello_from_esp32"),
                Term::Pid(self_pid),
            ]);

            info!("Sending message to 'esp_handler'...");
            match node.reg_send("esp_handler", message) {
                Ok(()) => info!("Message sent successfully!"),
                Err(e) => error!("Failed to send message: {}", e),
            }

            // Wait a bit for response
            std::thread::sleep(std::time::Duration::from_secs(2));

            node.disconnect();
            info!("Disconnected.");
        }
        Err(e) => {
            error!("Failed to connect to Erlang node: {}", e);
        }
    }

    info!("ESP32 Erlang node demo complete.");

    // Keep the program running
    loop {
        std::thread::sleep(std::time::Duration::from_secs(10));
    }
}
