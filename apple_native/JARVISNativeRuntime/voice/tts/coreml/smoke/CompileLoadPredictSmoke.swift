import CoreML
import CryptoKit
import Foundation
@_spi(Bootstrap) @_spi(Smoke) import JARVISCoreMLTTS

struct ModelSpec {
    let name: String
    let packageURL: URL
    let computeUnits: MLComputeUnits
    let unitsLabel: String
}

func lowerBoundShape(for constraint: MLMultiArrayConstraint) -> [NSNumber] {
    let fixedShape = constraint.shape.map { max(1, $0.intValue) }
    let ranges = constraint.shapeConstraint.sizeRangeForDimension
    if ranges.count == fixedShape.count {
        return ranges.enumerated().map { index, value in
            let range = value.rangeValue
            let lower = max(1, range.location)
            let fixed = fixedShape[index]
            return NSNumber(value: fixed > 1 ? fixed : lower)
        }
    }
    return fixedShape.map { NSNumber(value: $0) }
}

func zeroArray(_ array: MLMultiArray) {
    for index in 0..<array.count {
        array[index] = 0
    }
}

func featureProvider(for model: MLModel) throws -> MLFeatureProvider {
    var features: [String: MLFeatureValue] = [:]
    let inputs = model.modelDescription.inputDescriptionsByName
    for name in inputs.keys.sorted() {
        guard let description = inputs[name] else { continue }
        guard let constraint = description.multiArrayConstraint else {
            throw NSError(domain: "Smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported non-MLMultiArray input \(name)"])
        }
        let shape = lowerBoundShape(for: constraint)
        let array = try MLMultiArray(shape: shape, dataType: constraint.dataType)
        zeroArray(array)
        features[name] = MLFeatureValue(multiArray: array)
        print("INPUT \(name) shape=\(shape.map { $0.intValue }) type=\(constraint.dataType.rawValue)")
    }
    return try MLDictionaryFeatureProvider(dictionary: features)
}

func smoke(_ spec: ModelSpec, skipFlowPredict: Bool) throws {
    let config = MLModelConfiguration()
    config.computeUnits = spec.computeUnits
    let model = try XTTSCoreMLPipeline.loadModel(packageURL: spec.packageURL, configuration: config)
    print("LOAD OK \(spec.name) [\(spec.unitsLabel)]")

    if skipFlowPredict && spec.name == "flow_decoder" {
        print("PREDICT SKIPPED (jetsam) \(spec.name)")
        return
    }

    let provider = try featureProvider(for: model)
    let output = try model.prediction(from: provider)
    let outputNames = output.featureNames.sorted()
    guard !outputNames.isEmpty else {
        throw NSError(domain: "Smoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "No outputs for \(spec.name)"])
    }
    for name in outputNames {
        guard output.featureValue(for: name)?.multiArrayValue != nil else {
            throw NSError(domain: "Smoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Output \(name) for \(spec.name) is not MLMultiArray"])
        }
    }
    print("PREDICT OK \(spec.name) outputs=\(outputNames)")
}

let args = CommandLine.arguments
let modelDir = args.count > 1 ? URL(fileURLWithPath: args[1]) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("JARVISNativeRuntime/voice/tts/coreml/models")
let skipFlowPredict = args.contains("--skip-flow-predict")
let prewarmOnly = args.contains("--prewarm-only")
let specs = [
    ModelSpec(name: "text_encoder", packageURL: modelDir.appendingPathComponent("text_encoder.mlpackage"), computeUnits: .all, unitsLabel: "all"),
    ModelSpec(name: "flow_decoder", packageURL: modelDir.appendingPathComponent("flow_decoder.mlpackage"), computeUnits: .cpuAndGPU, unitsLabel: "cpuAndGPU"),
    ModelSpec(name: "mimi_decoder", packageURL: modelDir.appendingPathComponent("mimi_decoder.mlpackage"), computeUnits: .all, unitsLabel: "all"),
]

do {
    if prewarmOnly {
        let vsURL = modelDir.appendingPathComponent("voice_state.bin")
        let data = try Data(contentsOf: vsURL)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try XTTSCoreMLPipeline.preWarmAllModels(
            modelsRoot: modelDir,
            expectedVoiceStateSHA256Hex: sha
        )
    } else {
        for spec in specs {
            _ = try XTTSCoreMLPipeline.ensureCompiledModel(packageURL: spec.packageURL)
            try smoke(spec, skipFlowPredict: skipFlowPredict)
        }
    }
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    fputs("SMOKE ERROR: \(message)\n", stderr)
    exit(1)
}
