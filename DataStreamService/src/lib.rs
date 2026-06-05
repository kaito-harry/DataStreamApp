//! DuplexStreamService — dev environment stream echo-back service.

use actr_framework::{Context, Dest, entry};
use actr_protocol::{ActorResult, ActrId, DataStream, PayloadType};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

// ── Prost-generated types (proto package = "local") ──────────────────────
mod local {
    include!(concat!(env!("OUT_DIR"), "/local.rs"));
}

// ── Framework-generated actor code ────────────────────────────────────────
mod duplex_stream_actor {
    include!(concat!(env!("OUT_DIR"), "/duplex_stream_actor.rs"));
}

use duplex_stream_actor::*;
use local::*;

// ── Business Logic ────────────────────────────────────────────────────────

struct SessionState {
    c2s_id: String,
    s2c_id: String,
    chunks_received: u32,
}

pub struct DuplexStreamService {
    sessions: Arc<Mutex<HashMap<String, SessionState>>>,
}

impl DuplexStreamService {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

#[async_trait::async_trait]
impl DuplexStreamServiceHandler for DuplexStreamService {
    async fn start_duplex_stream<C: Context>(
        &self,
        req: StartDuplexStreamRequest,
        ctx: &C,
    ) -> ActorResult<StartDuplexStreamResponse> {
        let c2s_id = req.client_to_service_stream_id.clone();
        let s2c_id = req.service_to_client_stream_id.clone();
        let chunk_count = req.chunk_count;
        let payload_mode = req.payload_mode();

        tracing::info!(
            "StartDuplexStream: c2s={}, s2c={}, count={}, mode={:?}",
            c2s_id, s2c_id, chunk_count, payload_mode
        );

        let ctx_clone = ctx.clone();
        let sessions = self.sessions.clone();
        let c2s = c2s_id.clone();
        let s2c = s2c_id.clone();

        let echo_payload_type = match payload_mode {
            StreamPayloadMode::StreamReliable => PayloadType::StreamReliable,
            StreamPayloadMode::StreamLatencyFirst => PayloadType::StreamLatencyFirst,
        };

        ctx.register_stream(c2s_id.clone(), move |chunk: DataStream, sender: ActrId| {
            let sessions = sessions.clone();
            let c2s = c2s.clone();
            let s2c = s2c.clone();
            let ctx = ctx_clone.clone();

            Box::pin(async move {
                let original_seq = chunk.sequence;
                let session_id = chunk
                    .metadata
                    .iter()
                    .find(|m| m.key == "session_id")
                    .map(|m| m.value.clone())
                    .unwrap_or_default();

                let mut ack_meta = vec![];
                if !session_id.is_empty() {
                    ack_meta.push(actr_protocol::MetadataEntry {
                        key: "session_id".into(),
                        value: session_id,
                    });
                }
                ack_meta.push(actr_protocol::MetadataEntry {
                    key: "direction".into(),
                    value: "service-to-client".into(),
                });
                ack_meta.push(actr_protocol::MetadataEntry {
                    key: "ack_for_sequence".into(),
                    value: original_seq.to_string(),
                });
                ack_meta.push(actr_protocol::MetadataEntry {
                    key: "source_stream_id".into(),
                    value: c2s.clone(),
                });

                let ack = DataStream {
                    stream_id: s2c.clone(),
                    sequence: original_seq + 1000,
                    payload: chunk.payload.clone(),
                    metadata: ack_meta,
                    timestamp_ms: None,
                };

                tracing::info!(
                    "Echoing chunk seq={} -> {} on s2c={}",
                    original_seq,
                    original_seq + 1000,
                    s2c
                );

                if let Err(e) = ctx.send_data_stream(
                    &Dest::Actor(sender),
                    ack,
                    echo_payload_type,
                ).await {
                    tracing::error!("Failed to echo chunk: {:?}", e);
                }

                {
                    let mut sessions = sessions.lock().await;
                    if let Some(state) = sessions.get_mut(&c2s) {
                        state.chunks_received += 1;
                    }
                }

                Ok(())
            })
        }).await?;

        tracing::info!("Registered c2s stream callback: {}", c2s_id);

        self.sessions.lock().await.insert(
            c2s_id.clone(),
            SessionState {
                c2s_id: c2s_id.clone(),
                s2c_id: s2c_id.clone(),
                chunks_received: 0,
            },
        );

        Ok(StartDuplexStreamResponse {
            ready: true,
            message: format!("c2s={} s2c={} expecting {} chunks", c2s_id, s2c_id, chunk_count),
        })
    }

    async fn finish_duplex_stream<C: Context>(
        &self,
        req: FinishDuplexStreamRequest,
        ctx: &C,
    ) -> ActorResult<FinishDuplexStreamResponse> {
        tracing::info!(
            "FinishDuplexStream: c2s={}, s2c={}",
            req.client_to_service_stream_id,
            req.service_to_client_stream_id
        );

        ctx.unregister_stream(&req.client_to_service_stream_id).await?;

        let state = {
            let mut sessions = self.sessions.lock().await;
            sessions.remove(&req.client_to_service_stream_id)
        };

        let received = state.map(|s| s.chunks_received).unwrap_or(0);
        tracing::info!("FinishDuplexStream complete: received={}", received);

        Ok(FinishDuplexStreamResponse {
            acknowledged: true,
            message: format!("received={}", received),
        })
    }
}

// ── Entry Point ───────────────────────────────────────────────────────────

entry!(
    DuplexStreamServiceWorkload<DuplexStreamService>,
    DuplexStreamServiceWorkload::new(DuplexStreamService::new())
);
