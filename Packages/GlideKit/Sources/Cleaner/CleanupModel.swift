import GlideCore

/// Glide's cleanup model for Core ML: two 8-bit halves for the Neural Engine, the fp16 head and the embedding, 1.5 GB.
/// Every file is checked against the hash recorded here before it is used.
enum CleanupModel {
    // shortcut: not uploaded yet (the account's private HF storage is full), so downloads fail; pin the revision once it is.
    static let model = HubModel(
        repo: "Stelath/glide-cleanup-qwen3.5-0.8b-coreml", revision: "main",
        files: [
            .init("body0.mlpackage/Manifest.json", 617, .sha256("06d922bc95ff5851894cb21f3397461257fda6ffe3aa8ec2a5af4e1bcf000d32")),
            .init("body0.mlpackage/Data/com.apple.CoreML/model.mlmodel", 523556, .sha256("0059a1024050bc35a879fc1d7092f2de9ce036413f607e8963a925faaef5d36f")),
            .init("body0.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 251963776, .sha256("c81813b141facfbbfe13c9e7beb456ec74ad4594deac5e6c72a0d3ff0640d962")),
            .init("body1.mlpackage/Manifest.json", 617, .sha256("7dcdc1fef4fde1ca5b2f806deca0e6c567f20ea1edfa951547aeb228b380f994")),
            .init("body1.mlpackage/Data/com.apple.CoreML/model.mlmodel", 526002, .sha256("3b1e9a3a653bef64f527876e0977ad2191741cb923201b26695caa366d1cd19e")),
            .init("body1.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 251965888, .sha256("73124079b602f160b4d1b0266887b3ea09fe2cd78e7414b2775c6dcd3e100f78")),
            .init("head.mlpackage/Manifest.json", 617, .sha256("7c174405241e204562a2cceb2cd089af0df4f55129b9a173a3f1369c0a20975d")),
            .init("head.mlpackage/Data/com.apple.CoreML/model.mlmodel", 28369, .sha256("247b2cf9ff773d0670a67aaedcb18e609f5fd8e3cd4eebb559156b0b944df7e9")),
            .init("head.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 508591552, .sha256("2391cf5ada05297c2fc3297dc0b601acb0c37040fc8e4a25d34febd7ffac07b7")),
            .init("embed.bin", 508559360, .sha256("c5c0087ad3cb783f960e7d261093fa73bec7a87f4a644cdbac108da6088edd0e")),
            .init("chat_template.jinja", 7755, .sha256("273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80")),
            .init("tokenizer.json", 19989339, .sha256("a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f")),
            .init("tokenizer_config.json", 1502, .sha256("4d2fc7899270dc76b57a7aa1d5ec3234e6a25934c6e2aea6166f989f1d453892")),
        ])
}
