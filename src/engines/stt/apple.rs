use anyhow::Result;

use crate::{audio::AudioFormat, engines::apple_bridge, profile::ProfileCollector};

pub struct AppleSpeechProvider {
    model_id: String,
    profile: ProfileCollector,
}

impl AppleSpeechProvider {
    pub fn new(model_id: &str, profile: ProfileCollector) -> Result<Self> {
        anyhow::ensure!(
            crate::engines::model_assets::apple_speech_locale_id(model_id).is_some(),
            "unknown Apple Speech model: {model_id}"
        );
        Ok(Self {
            model_id: model_id.to_string(),
            profile,
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
        let profile = self.profile.clone();
        tokio::task::spawn_blocking(move || {
            apple_bridge::transcribe_profiled(&audio, model_id, profile)
        })
        .await?
    }

    fn name(&self) -> &'static str {
        "Apple Speech"
    }
}
