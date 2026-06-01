use anyhow::Result;

use crate::{audio::AudioFormat, engines::apple_bridge};

pub struct AppleSpeechProvider {
    model_id: String,
}

impl AppleSpeechProvider {
    pub fn new(model_id: &str) -> Result<Self> {
        anyhow::ensure!(
            crate::engines::model_assets::apple_speech_locale_id(model_id).is_some(),
            "unknown Apple Speech model: {model_id}"
        );
        Ok(Self {
            model_id: model_id.to_string(),
        })
    }
}

#[async_trait::async_trait]
impl super::SttProvider for AppleSpeechProvider {
    async fn transcribe(&self, audio: &[u8], format: AudioFormat) -> Result<String> {
        match format {
            AudioFormat::Wav => {}
        }

        let audio = audio.to_vec();
        let model_id = self.model_id.clone();
        tokio::task::spawn_blocking(move || apple_bridge::transcribe(&audio, model_id)).await?
    }

    fn name(&self) -> &'static str {
        "Apple Speech"
    }
}
