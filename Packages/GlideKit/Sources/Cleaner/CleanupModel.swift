import GlideCore

/// Glide's cleanup model for Core ML: two 8-bit halves for the Neural Engine, the fp16 head and the embedding, 1.5 GB,
/// plus where the nightly trainer finds the weights and LoRA slots in the halves (train.json, train.safetensors).
/// Every file is checked against the hash recorded here before it is used.
enum CleanupModel {
    // shortcut: not uploaded yet (the account's private HF storage is full), so downloads fail; pin the revision once it is.
    static let model = HubModel(
        repo: "Stelath/glide-cleanup-qwen3.5-0.8b-coreml", revision: "main",
        files: [
            .init("body0.mlpackage/Manifest.json", 617, .sha256("6275ef0a805f164516a5ebee0bcaf4e390f1e983508fb71e900cc8a6f5d666ea")),
            .init("body0.mlpackage/Data/com.apple.CoreML/model.mlmodel", 562283, .sha256("d4e0a9ce276b25361c9a5d9245ec942fbaedc88e4d55f2ca4cc35fe0660f755b")),
            .init("body0.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 255662848, .sha256("068f6e033a6afd75ace4ca5e12256191a40fcc9f5fcfb597b2135cfaadb8a19f")),
            .init("body1.mlpackage/Manifest.json", 617, .sha256("9ccfa2d80c913b7f2c65e82b5261987f6ff58b1fdb4f568d8f536b4ec32521a4")),
            .init("body1.mlpackage/Data/com.apple.CoreML/model.mlmodel", 564828, .sha256("8bc772ab40ed3bfbadcddf714c76a4b711d04d4bc37b3128c654e8e443d85ca8")),
            .init("body1.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 255664960, .sha256("7e80b1b69e997d09c4e247f8fb65ffd1ddf38ebaf0265ffcbbea729e007a48e9")),
            .init("head.mlpackage/Manifest.json", 617, .sha256("7c174405241e204562a2cceb2cd089af0df4f55129b9a173a3f1369c0a20975d")),
            .init("head.mlpackage/Data/com.apple.CoreML/model.mlmodel", 28369, .sha256("247b2cf9ff773d0670a67aaedcb18e609f5fd8e3cd4eebb559156b0b944df7e9")),
            .init("head.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 508591552, .sha256("2391cf5ada05297c2fc3297dc0b601acb0c37040fc8e4a25d34febd7ffac07b7")),
            .init("train.json", 19149, .sha256("faf7b5942650cb431a1f8c69562c362ae8839cbca3be0008b03df6178daf4221")),
            .init("train.safetensors", 4367024, .sha256("4483e8c7d92f5f2c09b480121c1e1513db46e7e23eb1b1d7d04587c43e6adbea")),
            .init("embed.bin", 508559360, .sha256("c5c0087ad3cb783f960e7d261093fa73bec7a87f4a644cdbac108da6088edd0e")),
            .init("chat_template.jinja", 7755, .sha256("273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80")),
            .init("tokenizer.json", 19989339, .sha256("a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f")),
            .init("tokenizer_config.json", 1502, .sha256("4d2fc7899270dc76b57a7aa1d5ec3234e6a25934c6e2aea6166f989f1d453892")),
        ])
}
