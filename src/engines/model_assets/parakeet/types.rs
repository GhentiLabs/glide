#[derive(Debug, Clone, Copy)]
pub struct ParakeetModelDefinition {
    pub id: &'static str,
    pub label: &'static str,
    pub language: &'static str,
    pub url: &'static str,
    pub archive_name: &'static str,
}

pub const PARAKEET_MODELS: [ParakeetModelDefinition; 2] = [
    ParakeetModelDefinition {
        id: "parakeet-tdt-0.6b-v2-int8",
        label: "Parakeet TDT 0.6B v2 int8",
        language: "English",
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
        archive_name: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
    },
    ParakeetModelDefinition {
        id: "parakeet-tdt-0.6b-v3-int8",
        label: "Parakeet TDT 0.6B v3 int8",
        language: "25 European languages",
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2",
        archive_name: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2",
    },
];

pub fn parakeet_definition(id: &str) -> Option<&'static ParakeetModelDefinition> {
    PARAKEET_MODELS.iter().find(|model| model.id == id)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParakeetInstallState {
    NotInstalled,
    Downloading {
        downloaded_bytes: u64,
        total_bytes: Option<u64>,
    },
    Cancelling {
        downloaded_bytes: u64,
        total_bytes: Option<u64>,
    },
    Installed {
        size_bytes: u64,
    },
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct ParakeetModelStatus {
    pub definition: ParakeetModelDefinition,
    pub state: ParakeetInstallState,
}
