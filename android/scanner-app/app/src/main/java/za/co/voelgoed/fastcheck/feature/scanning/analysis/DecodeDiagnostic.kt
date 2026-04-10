package za.co.voelgoed.fastcheck.feature.scanning.analysis

enum class DecodeDiagnostic {
    FrameReceived,
    MediaImageMissing,
    DecodeFailure,
    DecodeNoUsableRawValue,
    DecodeHandoffStarted
}
