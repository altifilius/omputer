use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::Value;
use tokio::io::{AsyncBufRead, AsyncBufReadExt};

pub const FRAME_BYTES: usize = 1024 * 1024;
pub const LOGICAL_BYTES: usize = 64 * 1024 * 1024;
const CHUNK_BYTES: usize = 256 * 1024;
struct Pending {
    id: String,
    count: usize,
    length: usize,
    index: usize,
    bytes: Vec<u8>,
}
#[derive(Default)]
pub struct Decoder {
    pending: Option<Pending>,
}
impl Decoder {
    pub fn push(&mut self, value: Value) -> Result<Option<Value>> {
        if !value.is_object() {
            bail!("RPC frame must be an object");
        }
        if value["type"] != "rpc_chunk" {
            if self.pending.is_some() {
                bail!("RPC chunk sequence interrupted");
            }
            return Ok(Some(value));
        }
        let id = value["chunkId"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 128)
            .context("Invalid RPC chunk id")?;
        let number = |key: &str| -> Result<usize> {
            usize::try_from(value[key].as_u64().context("Invalid RPC chunk integer")?)
                .context("RPC chunk integer overflow")
        };
        let index = number("index")?;
        let count = number("count")?;
        let length = number("byteLength")?;
        if !(2..=LOGICAL_BYTES / CHUNK_BYTES).contains(&count)
            || index >= count
            || !(FRAME_BYTES..=LOGICAL_BYTES).contains(&length)
        {
            bail!("Invalid RPC chunk metadata");
        }
        let encoded = value["data"].as_str().context("Invalid RPC chunk data")?;
        if encoded.len() > CHUNK_BYTES.div_ceil(3) * 4 {
            bail!("RPC chunk payload exceeds limit");
        }
        let bytes = STANDARD
            .decode(encoded)
            .context("Invalid RPC chunk base64")?;
        if bytes.is_empty() || bytes.len() > CHUNK_BYTES {
            bail!("Invalid RPC chunk payload length");
        }
        if self.pending.is_none() {
            if index != 0 {
                bail!("RPC chunk sequence must start at zero");
            }
            self.pending = Some(Pending {
                id: id.to_owned(),
                count,
                length,
                index: 0,
                bytes: Vec::with_capacity(length),
            });
        }
        let pending = self.pending.as_mut().unwrap();
        if pending.id != id
            || pending.count != count
            || pending.length != length
            || pending.index != index
        {
            bail!("RPC chunk sequence mismatch");
        }
        if pending.bytes.len() + bytes.len() > length {
            bail!("RPC chunks exceed declared length");
        }
        pending.bytes.extend_from_slice(&bytes);
        pending.index += 1;
        if pending.index < count {
            return Ok(None);
        }
        let pending = self.pending.take().unwrap();
        if pending.bytes.len() != length {
            bail!("RPC chunk length mismatch");
        }
        let frame: Value =
            serde_json::from_slice(&pending.bytes).context("Invalid reassembled RPC JSON/UTF-8")?;
        if !frame.is_object() || frame["type"] == "rpc_chunk" {
            bail!("Invalid reassembled RPC frame");
        }
        Ok(Some(frame))
    }
    pub fn finish(&self) -> Result<()> {
        if self.pending.is_some() {
            bail!("Incomplete RPC chunk sequence at disconnect");
        }
        Ok(())
    }
}
pub async fn line<R: AsyncBufRead + Unpin>(reader: &mut R, limit: usize) -> Result<Option<String>> {
    let mut bytes = Vec::new();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            if bytes.is_empty() {
                return Ok(None);
            }
            bail!("Incomplete JSONL frame at disconnect");
        }
        let count = available
            .iter()
            .position(|b| *b == b'\n')
            .map(|n| n + 1)
            .unwrap_or(available.len());
        if bytes.len() + count > limit {
            bail!("JSONL frame exceeds transport limit");
        }
        let done = available[count - 1] == b'\n';
        bytes.extend_from_slice(&available[..count]);
        reader.consume(count);
        if done {
            bytes.pop();
            return Ok(Some(
                String::from_utf8(bytes).context("Invalid JSONL UTF-8")?,
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn chunks(value: &Value) -> Vec<Value> {
        let bytes = serde_json::to_vec(value).unwrap();
        let count = bytes.len().div_ceil(CHUNK_BYTES);
        bytes.chunks(CHUNK_BYTES).enumerate().map(|(index,part)|json!({"type":"rpc_chunk","chunkId":"a","index":index,"count":count,"byteLength":bytes.len(),"data":STANDARD.encode(part)})).collect()
    }
    #[test]
    fn chunk_boundaries_preserve_unicode_and_complete_message() {
        for extra in [0, 1, 2, 3, CHUNK_BYTES - 1] {
            let frame = json!({"type":"message_end","message":{"role":"assistant","content":"ş🦀".repeat(FRAME_BYTES/6+extra)}});
            let mut decoder = Decoder::default();
            let mut result = None;
            for chunk in chunks(&frame) {
                result = decoder.push(chunk).unwrap();
            }
            assert_eq!(result, Some(frame));
            decoder.finish().unwrap();
        }
    }
    #[test]
    fn invalid_chunk_sequences_are_rejected() {
        let frame = json!({"type":"response","data":"x".repeat(FRAME_BYTES)});
        let frames = chunks(&frame);
        let mut d = Decoder::default();
        assert!(d.push(frames[1].clone()).is_err());
        let mut d = Decoder::default();
        d.push(frames[0].clone()).unwrap();
        assert!(d.push(json!({"type":"agent_end"})).is_err());
        let mut d = Decoder::default();
        d.push(frames[0].clone()).unwrap();
        let mut other = frames[1].clone();
        other["chunkId"] = json!("b");
        assert!(d.push(other).is_err());
        let mut d = Decoder::default();
        d.push(frames[0].clone()).unwrap();
        assert!(d.push(frames[2].clone()).is_err());
        let mut d = Decoder::default();
        d.push(frames[0].clone()).unwrap();
        assert!(d.finish().is_err());
        for delta in [-1, 1] {
            let mut d = Decoder::default();
            let mut rejected = false;
            for mut chunk in frames.clone() {
                chunk["byteLength"] = json!(chunk["byteLength"].as_i64().unwrap() + delta);
                if d.push(chunk).is_err() {
                    rejected = true;
                    break;
                }
            }
            assert!(rejected);
        }
        let mut bad = frames[0].clone();
        bad["byteLength"] = json!(LOGICAL_BYTES + 1);
        assert!(Decoder::default().push(bad).is_err());
    }
}
