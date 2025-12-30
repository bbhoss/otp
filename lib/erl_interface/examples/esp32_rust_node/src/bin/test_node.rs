//! Test binary for desktop testing of the Erlang node implementation
//!
//! Usage:
//!   cargo run --bin test_node -- <host> <port> <cookie>
//!
//! Example:
//!   cargo run --bin test_node -- 127.0.0.1 9000 testcookie

use erlang_node::{CNode, Term};
use std::env;

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("debug")).init();

    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("Usage: {} <host> <port> <cookie>", args[0]);
        eprintln!("Example: {} 127.0.0.1 9000 testcookie", args[0]);
        std::process::exit(1);
    }

    let host = &args[1];
    let port: u16 = args[2].parse().expect("Invalid port number");
    let cookie = &args[3];

    println!("=== Rust Erlang Node Test ===");
    println!("Connecting to {}:{} with cookie '{}'", host, port, cookie);

    // Create our C-node with the system hostname
    let hostname = std::process::Command::new("hostname")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|_| "localhost".to_string());
    let mut node = CNode::new("rust_node", &hostname, cookie);
    println!("Created node: {}", node.node_name());

    // Connect to Erlang node
    match node.connect(host, port) {
        Ok(()) => {
            println!("Successfully connected!");

            // Get our self pid
            let self_pid = node.self_pid();
            println!("Our PID: {:?}", self_pid);

            // Send a message to registered process 'esp_handler'
            let message = Term::tuple(vec![
                Term::atom("hello_from_rust"),
                Term::Pid(self_pid),
            ]);

            println!("Sending message to 'esp_handler': {:?}", message);
            match node.reg_send("esp_handler", message) {
                Ok(()) => println!("Message sent successfully!"),
                Err(e) => eprintln!("Failed to send message: {}", e),
            }

            // Try to receive a response (with timeout)
            println!("Waiting for response...");

            // For now, just disconnect after sending
            std::thread::sleep(std::time::Duration::from_secs(1));
            node.disconnect();
            println!("Disconnected.");
        }
        Err(e) => {
            eprintln!("Failed to connect: {}", e);
            std::process::exit(1);
        }
    }
}
