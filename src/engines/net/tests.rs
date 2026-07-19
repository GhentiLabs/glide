use super::*;
use std::{
    io::{Read as _, Write as _},
    net::TcpListener,
    thread,
};

/// Serves each response to one connection in order, then exits. Panics (test
/// hang) if the client makes fewer connections than there are responses.
struct SequenceServer {
    url: String,
    handle: thread::JoinHandle<usize>,
}

impl SequenceServer {
    fn try_spawn(responses: Vec<(&'static str, &'static str)>) -> Option<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").ok()?;
        let addr = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let mut served = 0;
            for (status_line, body) in responses {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 65536];
                let _ = stream.read(&mut request).unwrap_or(0);
                let response = format!(
                    "HTTP/1.1 {status_line}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                stream.write_all(response.as_bytes()).unwrap();
                served += 1;
            }
            served
        });

        Some(Self {
            url: format!("http://{addr}/"),
            handle,
        })
    }

    fn join(self) -> usize {
        self.handle.join().unwrap()
    }
}

#[tokio::test]
async fn returns_first_success_without_retry() {
    let Some(server) = SequenceServer::try_spawn(vec![("200 OK", r#"{"ok":true}"#)]) else {
        eprintln!("skipping: loopback sockets unavailable");
        return;
    };
    let client = client(LLM_TIMEOUT);

    let response = send_with_retry(|| Ok(client.get(&server.url)), "test API")
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(server.join(), 1);
}

#[tokio::test]
async fn retries_once_on_server_error_then_succeeds() {
    let Some(server) = SequenceServer::try_spawn(vec![
        ("500 Internal Server Error", "boom"),
        ("200 OK", r#"{"ok":true}"#),
    ]) else {
        eprintln!("skipping: loopback sockets unavailable");
        return;
    };
    let client = client(LLM_TIMEOUT);

    let response = send_with_retry(|| Ok(client.get(&server.url)), "test API")
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(server.join(), 2);
}

#[tokio::test]
async fn retries_once_on_rate_limit_and_returns_second_outcome() {
    let Some(server) = SequenceServer::try_spawn(vec![
        ("429 Too Many Requests", "slow down"),
        ("429 Too Many Requests", "still busy"),
    ]) else {
        eprintln!("skipping: loopback sockets unavailable");
        return;
    };
    let client = client(LLM_TIMEOUT);

    let response = send_with_retry(|| Ok(client.get(&server.url)), "test API")
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(server.join(), 2);
}

#[tokio::test]
async fn does_not_retry_permanent_client_errors() {
    let Some(server) = SequenceServer::try_spawn(vec![("401 Unauthorized", "bad key")]) else {
        eprintln!("skipping: loopback sockets unavailable");
        return;
    };
    let client = client(LLM_TIMEOUT);

    let response = send_with_retry(|| Ok(client.get(&server.url)), "test API")
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(server.join(), 1);
}

#[tokio::test]
async fn retries_on_connect_error() {
    // Bind then drop to get a port with nothing listening.
    let port = {
        let listener = match TcpListener::bind("127.0.0.1:0") {
            Ok(listener) => listener,
            Err(_) => {
                eprintln!("skipping: loopback sockets unavailable");
                return;
            }
        };
        listener.local_addr().unwrap().port()
    };
    let client = client(LLM_TIMEOUT);
    let url = format!("http://127.0.0.1:{port}/");

    let error = send_with_retry(|| Ok(client.get(&url)), "test API")
        .await
        .unwrap_err();

    assert!(error.to_string().contains("failed to call test API"));
}
