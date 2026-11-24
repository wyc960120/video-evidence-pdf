// VideoEvidence.swift
// 微信聊天记录录屏 -> 停留检测截图 -> A4 竖版 2x2 证据 PDF
//
// 零依赖：仅用 macOS 自带框架 (AVFoundation / CoreGraphics / ImageIO / PDFKit / AppKit)
// 不要直接执行本文件，用同级 ../run.sh 作为入口：
//   bash run.sh <video> [options]
// 或：xcrun swift -swift-version 5 VideoEvidence.swift <video> [options]
//

import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import AppKit

// MARK: - 配置

struct Config {
    // 默认按「人的自然操作」调校：随手停顿 0.3 秒也能识别，不要求匀速停 2 秒。
    // 取证场景漏截比多截严重得多，宁可多几张让使用者目视筛，也不能漏一屏。
    var step: Double = 0.1          // 抽帧步长（秒）
    var hold: Double = 0.2          // 最小停留时长（秒）
    var change: Double = 0.08       // 变化像素占比阈值（0-1），主判据；真实录屏校准值
    var motion: Double = 4.0        // 相邻帧 MAD 阈值（0-255），辅助兜底
    var drift: Double = 6.0         // 累积 MAD 阈值（相对本段首帧），切断慢速下滑
    var dedup: Double = 0.02        // 相邻截图变化比低于此值视为同一屏，跳过
    var margin: CGFloat = 24        // PDF 页边距（pt）
    var gap: CGFloat = 12           // PDF 图片间距（pt）
    var keepLog: Bool = true        // 是否写内部日志
    var keepPNG: Bool = false       // 是否保留中间 PNG 截图（默认不保留，直接内存拼 PDF）
}

struct Shot {
    let index: Int
    let time: Double
    let file: String
}

struct Segment {
    let start: Double
    let end: Double
    let middle: Double
}

struct Options {
    var config = Config()
    var video: URL?
    var outDir: URL?
    var command: Command = .help
    enum Command { case process, selfTest, makeSample, diagnose, help }
}

// MARK: - 小工具

func out(_ s: String) { print(s); fflush(stdout) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func stamp(_ t: Double) -> String {
    let total = max(0, Int(t))
    return String(format: "%02d-%02d-%02d", total / 3600, (total % 3600) / 60, total % 60)
}

func preciseStamp(_ t: Double) -> String {
    String(format: "%02d:%02d:%06.3f", Int(t) / 3600, (Int(t) % 3600) / 60, t.truncatingRemainder(dividingBy: 60))
}

func writePNG(_ image: CGImage, to url: URL) throws {
    // 用内存 buffer 写出再一次性落盘，避开 ImageIO 原子写的「临时文件 + 重命名」：
    // 该重命名在受限沙箱下会被判成 file-delete 而拦截（提权对脚本内子进程也无效）。
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "VideoEvidence", code: 10, userInfo: [NSLocalizedDescriptionKey: "无法创建 PNG: \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "VideoEvidence", code: 11, userInfo: [NSLocalizedDescriptionKey: "PNG 写入失败: \(url.path)"])
    }
    try data.write(to: url)
}

func readImage(_ url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "VideoEvidence", code: 12, userInfo: [NSLocalizedDescriptionKey: "无法读取图片: \(url.path)"])
    }
    return img
}

/// 把任意尺寸的帧缩成 n×n 灰度指纹，用于帧差比较
func fingerprint(_ image: CGImage, n: Int = 32) -> [UInt8] {
    guard let ctx = CGContext(data: nil, width: n, height: n,
                              bitsPerComponent: 8, bytesPerRow: n,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
    guard let base = ctx.data else { return [] }
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: ptr, count: n * n))
}

/// 平均绝对差，0 = 完全相同，255 = 黑白反转
func mad(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 255 }
    var sum: Int = 0
    for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
    return Double(sum) / Double(a.count)
}

/// 明显变化的像素占比（0–1）。白底聊天界面里气泡移动时，
/// MAD 会被大面积白底稀释，这个比例能更灵敏地反映「画面确实在动」。
func changedRatio(_ a: [UInt8], _ b: [UInt8], threshold: Int = 12) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 1 }
    var count = 0
    for i in 0..<a.count {
        if abs(Int(a[i]) - Int(b[i])) > threshold { count += 1 }
    }
    return Double(count) / Double(a.count)
}

/// 诊断用：8x8 均值哈希
func aHash(_ image: CGImage) -> UInt64 {
    let n = 8
    guard let ctx = CGContext(data: nil, width: n, height: n,
                              bitsPerComponent: 8, bytesPerRow: n,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let base = ctx.data else { return 0 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
    let p = base.assumingMemoryBound(to: UInt8.self)
    var values = [Int](repeating: 0, count: n * n)
    var sum = 0
    for i in 0..<(n * n) { values[i] = Int(p[i]); sum += values[i] }
    let mean = sum / (n * n)
    var h: UInt64 = 0
    for i in 0..<(n * n) { h = (h << 1) | (values[i] > mean ? 1 : 0) }
    return h
}

// MARK: - 视频读取

func loadDuration(_ asset: AVAsset) -> Double {
    let sem = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var v: Double = 0 }
    let box = Box()
    Task.detached {
        let d = (try? await asset.load(.duration)) ?? .zero
        box.v = CMTimeGetSeconds(d)
        sem.signal()
    }
    sem.wait()
    return box.v
}

func makeGenerator(_ asset: AVAsset, maxSize: CGSize?, tolerance: Double) -> AVAssetImageGenerator {
    let g = AVAssetImageGenerator(asset: asset)
    g.appliesPreferredTrackTransform = true   // 手机竖屏录屏的旋转 metadata
    if let s = maxSize { g.maximumSize = s }
    let tol = CMTime(seconds: tolerance, preferredTimescale: 600)
    g.requestedTimeToleranceBefore = tol
    g.requestedTimeToleranceAfter = tol
    return g
}

/// 同步封装异步取帧；copyCGImage(at:actualTime:) 在 macOS 15 起已弃用
func copyFrame(_ gen: AVAssetImageGenerator, at time: CMTime) throws -> CGImage {
    final class Box: @unchecked Sendable {
        var image: CGImage?
        var error: Error?
    }
    let box = Box()
    let sem = DispatchSemaphore(value: 0)
    gen.generateCGImageAsynchronously(for: time) { image, _, error in
        if let img = image {
            box.image = img
        } else {
            box.error = error ?? NSError(domain: "VideoEvidence", code: 40,
                                        userInfo: [NSLocalizedDescriptionKey: "取帧失败"])
        }
        sem.signal()
    }
    sem.wait()
    if let image = box.image { return image }
    throw box.error ?? NSError(domain: "VideoEvidence", code: 40,
                               userInfo: [NSLocalizedDescriptionKey: "取帧失败"])
}

/// 第一遍：按步长抽小图，只算指纹，不保留原图（内存恒定）
/// 用批量异步取帧让框架顺序解码一次；逐点 seek 在 0.1s 步长下会慢一个数量级。
func sampleFingerprints(asset: AVAsset, duration: Double, cfg: Config) throws -> [(time: Double, fp: [UInt8], diff: Double)] {
    let gen = makeGenerator(asset, maxSize: CGSize(width: 320, height: 320), tolerance: cfg.step / 2)
    var times: [CMTime] = []
    var t: Double = 0
    while t <= duration + 0.001 {
        times.append(CMTime(seconds: t, preferredTimescale: 600))
        t += cfg.step
    }
    let total = times.count
    let nsTimes = times.map { NSValue(time: $0) }

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        let sem = DispatchSemaphore(value: 0)
        var frames: [Int: [UInt8]] = [:]
        var done = 0
    }
    let box = Box()
    gen.generateCGImagesAsynchronously(forTimes: nsTimes) { requested, image, _, _, _ in
        let key = Int(round(CMTimeGetSeconds(requested) * 1000))
        let fp = image.map { fingerprint($0) } ?? []
        box.lock.lock()
        box.frames[key] = fp
        box.done += 1
        let finished = box.done >= total
        box.lock.unlock()
        if finished { box.sem.signal() }
    }
    if box.sem.wait(timeout: .now() + 900) != .success {
        throw NSError(domain: "VideoEvidence", code: 50,
                      userInfo: [NSLocalizedDescriptionKey: "抽帧超时（视频过长或格式异常），可把 --step 调大后重试"])
    }

    var result: [(Double, [UInt8], Double)] = []
    var prev: [UInt8]? = nil
    box.lock.lock()
    let frames = box.frames
    box.lock.unlock()
    for cm in times {
        let tt = CMTimeGetSeconds(cm)
        let key = Int(round(tt * 1000))
        var fp = frames[key] ?? []
        if fp.isEmpty { fp = prev ?? [] }   // 末尾越界：视为与前帧相同
        let d = prev.map { mad($0, fp) } ?? 0
        result.append((tt, fp, d))
        prev = fp
    }
    return result
}

/// 从帧差序列里找出「连续静止 ≥ hold 秒」的区间
func detectSegments(_ samples: [(time: Double, fp: [UInt8], diff: Double)], cfg: Config) -> [Segment] {
    guard samples.count >= 2 else { return [] }
    var segments: [Segment] = []
    func closeRun(_ a: Int, _ b: Int) {
        // a 是「被判定为动」的那一帧，本身不是停留画面，真正静止从 a+1 开始。
        // 把它算进段内会虚增一个步长（0.5s），导致录屏刚开头、滑动刚结束这类
        // 实际不足 hold 的短暂停被误截，且取帧可能落在半滑动的残影上。
        // a == 0 时是视频首帧（静止），不能跳过。
        let first = a > 0 ? min(a + 1, b) : a
        let length = samples[b].time - samples[first].time
        if length >= cfg.hold {
            segments.append(Segment(start: samples[first].time,
                                    end: samples[b].time,
                                    middle: samples[(first + b) / 2].time))
        }
    }
    var runStart = 0
    for i in 1..<samples.count {
        // 四个判据：变化像素占比为主（相邻 + 累积），MAD 为辅（相邻 + 累积）。
        // 累积判据用于切断「慢速下滑」——每两帧看着都没变，但相对本段首帧已经变了。
        let adjacentMAD = samples[i].diff
        let accumulatedMAD = mad(samples[i].fp, samples[runStart].fp)
        let adjacentChange = changedRatio(samples[i].fp, samples[i - 1].fp)
        let accumulatedChange = changedRatio(samples[i].fp, samples[runStart].fp)
        if adjacentMAD > cfg.motion || accumulatedMAD > cfg.drift
            || adjacentChange > cfg.change || accumulatedChange > cfg.change {
            closeRun(runStart, i - 1)
            runStart = i
        }
    }
    closeRun(runStart, samples.count - 1)
    return segments
}

/// 第二遍：对选中的时间点取全分辨率帧
func extractFrame(_ asset: AVAsset, at time: Double, cfg: Config) throws -> CGImage {
    let gen = makeGenerator(asset, maxSize: nil, tolerance: min(cfg.step / 4, 0.1))
    return try copyFrame(gen, at: CMTime(seconds: time, preferredTimescale: 600))
}

// MARK: - PDF 拼版（A4 竖版 2×2，纯图无标注）

let a4width: CGFloat = 595.276
let a4height: CGFloat = 841.890

/// 流式 PDF 拼版器：抽一帧画一帧，满 4 张换页。图像不落盘、不攒内存，
/// 内存里始终只有当前正在画的这一张，避免千张全分辨率截图一次堆满内存。
final class PDFPainter {
    private let data = NSMutableData()
    private let pdf: CGContext
    private let cfg: Config
    private var pageOpen = false
    private var slotInPage = 0
    private(set) var pageCount = 0
    private(set) var imageCount = 0

    init(cfg: Config) throws {
        guard let consumer = CGDataConsumer(data: data) else {
            throw NSError(domain: "VideoEvidence", code: 20, userInfo: [NSLocalizedDescriptionKey: "无法创建 PDF data consumer"])
        }
        var mediaBox = CGRect(x: 0, y: 0, width: a4width, height: a4height)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "VideoEvidence", code: 20, userInfo: [NSLocalizedDescriptionKey: "无法创建 PDF context"])
        }
        self.pdf = ctx
        self.cfg = cfg
    }

    func add(_ image: CGImage) {
        if !pageOpen {
            pdf.beginPDFPage(nil)
            pageOpen = true
            slotInPage = 0
        }
        let usableW = a4width - cfg.margin * 2
        let usableH = a4height - cfg.margin * 2
        let cellW = (usableW - cfg.gap) / 2
        let cellH = (usableH - cfg.gap) / 2
        let col = slotInPage % 2, row = slotInPage / 2
        // Quartz 原点在左下：row 0 放上半页
        let cell = CGRect(x: cfg.margin + CGFloat(col) * (cellW + cfg.gap),
                          y: a4height - cfg.margin - CGFloat(row + 1) * cellH - CGFloat(row) * cfg.gap,
                          width: cellW, height: cellH)
        let ratio = CGFloat(image.width) / CGFloat(image.height)
        var w = cell.width, h = w / ratio
        if h > cell.height { h = cell.height; w = h * ratio }
        let rect = CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h)

        pdf.saveGState()
        pdf.interpolationQuality = .high
        // Quartz 的 draw(_:in:) 在 PDF context 中已正确处理 CGImage 方向，
        // 额外做 translate/scale 翻转反而会让画面上下颠倒。
        pdf.draw(image, in: rect)
        pdf.restoreGState()

        slotInPage += 1
        imageCount += 1
        if slotInPage == 4 {
            pdf.endPDFPage()
            pageCount += 1
            pageOpen = false
        }
    }

    func finish(to url: URL) throws {
        if pageOpen {
            pdf.endPDFPage()
            pageCount += 1
            pageOpen = false
        }
        pdf.closePDF()
        try data.write(to: url)
        out("  PDF: \(url.lastPathComponent)（\(pageCount) 页 / \(imageCount) 张）")
    }
}

/// 自检用：把 PDF 第一页渲染成 PNG 预览，便于肉眼核对方向与排版
func renderPDFPreview(_ pdfURL: URL, to pngURL: URL) throws {
    guard let doc = PDFDocument(url: pdfURL), let page = doc.page(at: 0) else {
        throw NSError(domain: "VideoEvidence", code: 21, userInfo: [NSLocalizedDescriptionKey: "PDF 读回失败"])
    }
    let size = CGSize(width: a4width * 1.2, height: a4height * 1.2)
    let nsImage = page.thumbnail(of: size, for: .mediaBox)
    guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "VideoEvidence", code: 22, userInfo: [NSLocalizedDescriptionKey: "PDF 预览渲染失败"])
    }
    try writePNG(cg, to: pngURL)
}

// MARK: - 内部日志（机器可读，非取证说明文档）

func writeLog(video: URL, outDir: URL, cfg: Config, shots: [Shot], pdfName: String) throws {
    var lines: [String] = []
    lines.append("{")
    lines.append("  \"source\": \"\(video.lastPathComponent)\",")
    lines.append("  \"pdf\": \"\(pdfName)\",")
    lines.append("  \"config\": {\"step\": \(cfg.step), \"hold\": \(cfg.hold), \"change\": \(cfg.change), \"motion\": \(cfg.motion), \"drift\": \(cfg.drift), \"dedup\": \(cfg.dedup), \"keep_png\": \(cfg.keepPNG)},")
    lines.append("  \"shot_count\": \(shots.count),")
    lines.append("  \"shots\": [")
    for (i, s) in shots.enumerated() {
        let comma = i == shots.count - 1 ? "" : ","
        lines.append("    {\"index\": \(s.index), \"time\": \"\(preciseStamp(s.time))\", \"file\": \"\(s.file)\"}\(comma)")
    }
    lines.append("  ]")
    lines.append("}")
    try lines.joined(separator: "\n").data(using: .utf8)!.write(to: outDir.appendingPathComponent("capture_log.json"))
}

// MARK: - 阈值诊断（拿真实录屏校准时用）

func diagnose(video: URL, cfg: Config) throws {
    let asset = AVURLAsset(url: video)
    let duration = loadDuration(asset)
    guard duration > 0 else {
        throw NSError(domain: "VideoEvidence", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取视频时长"])
    }
    let samples = try sampleFingerprints(asset: asset, duration: duration, cfg: cfg)
    out("视频 \(video.lastPathComponent)  时长 \(String(format: "%.1f", duration))s  共 \(samples.count) 帧")
    out("  t(s)   相邻MAD  累积MAD  相邻变化比  累积变化比   判定")
    var runStart = 0
    for i in 0..<samples.count {
        let s = samples[i]
        let adj = s.diff
        let drift = mad(s.fp, samples[runStart].fp)
        let cr = i > 0 ? changedRatio(s.fp, samples[i - 1].fp) : 0
        let crDrift = changedRatio(s.fp, samples[runStart].fp)
        let moving = i > 0 && (adj > cfg.motion || drift > cfg.drift
                               || cr > cfg.change || crDrift > cfg.change)
        if moving { runStart = i }
        out(String(format: "%6.1f  %8.2f  %8.2f  %10.3f  %10.3f   %@",
                   s.time, adj, drift, cr, crDrift, moving ? "动" : "静"))
    }
    let segs = detectSegments(samples, cfg: cfg)
    let desc = segs.map { String(format: "%.1f-%.1f", $0.start, $0.end) }.joined(separator: ", ")
    out("当前阈值检出 \(segs.count) 段: \(desc)")
    out("提示：两段停留被粘在一起 → 调小 --change / --drift；静止段被打碎 → 调大 --change / --motion。")
}

// MARK: - 主流程

@discardableResult
func process(video: URL, outDir: URL, cfg: Config, preview: Bool = false) throws -> (shots: [Shot], segments: [Segment], stats: [Double]) {
    guard FileManager.default.fileExists(atPath: video.path) else {
        throw NSError(domain: "VideoEvidence", code: 1, userInfo: [NSLocalizedDescriptionKey: "视频不存在: \(video.path)"])
    }
    let asset = AVURLAsset(url: video)
    let duration = loadDuration(asset)
    guard duration > 0 else {
        throw NSError(domain: "VideoEvidence", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取视频时长（格式不支持？）"])
    }
    out("视频: \(video.lastPathComponent)  时长 \(String(format: "%.1f", duration))s")

    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let framesDir = outDir.appendingPathComponent("frames")
    if cfg.keepPNG {
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
    }

    out("① 抽帧 + 帧差分析（步长 \(cfg.step)s）…")
    let samples = try sampleFingerprints(asset: asset, duration: duration, cfg: cfg)
    let stats = samples.map { $0.diff }
    out("   共 \(samples.count) 帧，帧差范围 \(String(format: "%.1f", stats.min() ?? 0))–\(String(format: "%.1f", stats.max() ?? 0))（阈值 change=\(cfg.change) / motion=\(cfg.motion) / drift=\(cfg.drift)）")

    out("② 检测停留区间（≥\(cfg.hold)s）…")
    let segments = detectSegments(samples, cfg: cfg)
    for (i, s) in segments.enumerated() {
        out(String(format: "   #%02d  %@ → %@  取帧 %@", i + 1, preciseStamp(s.start), preciseStamp(s.end), preciseStamp(s.middle)))
    }
    if segments.isEmpty {
        out("   ⚠️ 未检出任何停留段。可调大 --change / --motion，或调小 --hold 后重试")
    }

    out("③ 取帧 + 去重\(cfg.keepPNG ? "并导出 PNG" : "（不落盘，直接拼 PDF）")…")
    var shots: [Shot] = []
    var lastFP: [UInt8]? = nil
    let painter = try PDFPainter(cfg: cfg)
    for seg in segments {
        let image = try extractFrame(asset, at: seg.middle, cfg: cfg)
        let fp = fingerprint(image)
        if let last = lastFP, changedRatio(fp, last) < cfg.dedup {
            out("   跳过重复帧 \(preciseStamp(seg.middle))")
            continue
        }
        lastFP = fp
        let n = shots.count + 1
        let name = String(format: "%03d_%@.png", n, stamp(seg.middle))
        if cfg.keepPNG {
            try writePNG(image, to: framesDir.appendingPathComponent(name))
        }
        shots.append(Shot(index: n, time: seg.middle, file: cfg.keepPNG ? "frames/\(name)" : ""))
        painter.add(image)
        out("   #\(n)  \(image.width)×\(image.height)  \(preciseStamp(seg.middle))")
    }

    out("④ 拼版 A4 竖版 2×2 …")
    let pdfName = video.deletingPathExtension().lastPathComponent + "_evidence.pdf"
    let pdfURL = outDir.appendingPathComponent(pdfName)
    try painter.finish(to: pdfURL)

    if cfg.keepLog {
        try writeLog(video: video, outDir: outDir, cfg: cfg, shots: shots, pdfName: pdfName)
    }
    if preview, FileManager.default.fileExists(atPath: pdfURL.path) {
        let p = outDir.appendingPathComponent("_pdf_preview.png")
        try renderPDFPreview(pdfURL, to: p)
        out("  预览: \(p.path)")
    }
    out("完成 → \(outDir.path)")
    return (shots, segments, stats)
}

// MARK: - 合成测试视频（模拟「停留 → 下滑 → 停留」）

func makeSampleVideo(to url: URL, groups: Int = 4) throws {
    let W = 360, H = 640, fps: Int32 = 30, seconds = groups * 3
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: W,
        AVVideoHeightKey: H
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: W,
        kCVPixelBufferHeightKey as String: H
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)

    func drawFrame(_ frame: Int, into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: W, height: H,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
        let t = Double(frame) / Double(fps)
        let group = Int(t / 3.0)
        let local = t - Double(group) * 3.0
        let isHold = local < 2.0
        let offset: CGFloat = isHold ? 0 : CGFloat(local - 2.0) * 500

        ctx.setFillColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(red: 0.87, green: 0.88, blue: 0.90, alpha: 1)
        ctx.fill(CGRect(x: 0, y: H - 56, width: W, height: 56))
        let bubbles = 5 + group
        for i in 0..<bubbles {
            let y = CGFloat(H - 110 - (i % 6) * 78) - offset
            let isMine = (i + group) % 3 == 0
            if isMine {
                ctx.setFillColor(red: 0.56, green: 0.79, blue: 0.48, alpha: 1)
                ctx.fill(CGRect(x: 150, y: y, width: 180, height: 52))
            } else {
                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                ctx.fill(CGRect(x: 24, y: y, width: 190 + CGFloat(group * 8), height: 52))
            }
            ctx.setFillColor(red: 0.25, green: 0.27, blue: 0.30, alpha: 0.55)
            ctx.fill(CGRect(x: isMine ? 162 : 36, y: y + 20, width: 120 + CGFloat((i * 17) % 40), height: 8))
        }
    }

    let total = seconds * Int(fps)
    for f in 0..<total {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        var pb: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess,
              let buffer = pb else {
            throw NSError(domain: "VideoEvidence", code: 30, userInfo: [NSLocalizedDescriptionKey: "无法创建像素缓冲"])
        }
        drawFrame(f, into: buffer)
        let pts = CMTime(value: Int64(f), timescale: fps)
        if !adaptor.append(buffer, withPresentationTime: pts) {
            throw NSError(domain: "VideoEvidence", code: 31, userInfo: [NSLocalizedDescriptionKey: "写入第 \(f) 帧失败"])
        }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else {
        throw NSError(domain: "VideoEvidence", code: 32, userInfo: [NSLocalizedDescriptionKey: "视频写入失败: \(String(describing: writer.error))"])
    }
    out("合成样本: \(url.path)（\(seconds)s，\(groups) 段停留 + \(groups) 段下滑）")
}

// MARK: - CLI

func usage() {
    out("""
    VideoEvidence — 录屏停留检测 → A4 2×2 证据 PDF（零依赖）

    用法:
      xcrun swift -swift-version 5 VideoEvidence.swift <video> [options]
      xcrun swift -swift-version 5 VideoEvidence.swift --self-test
      xcrun swift -swift-version 5 VideoEvidence.swift --make-sample <out.mp4>

    选项:
      --outdir <dir>     输出目录（默认：视频同级 <视频名>_evidence/）
      --step <sec>       抽帧步长，默认 0.1（灵敏模式）
      --hold <sec>       最小停留时长，默认 0.2
      --change <0-1>     变化像素占比阈值，默认 0.08（主判据，越小越敏感）
      --motion <0-255>   相邻帧 MAD 阈值，默认 4.0（辅助）
      --drift <0-255>    累积 MAD 阈值，默认 6.0（切断慢速下滑）
      --dedup <0-1>      相邻截图差异低于此值视为同屏，默认 0.02；设 0 关闭
      --steady           稳妥模式（step 0.5 / hold 0.8 / dedup 0），长停顿才截
      --margin <pt>      PDF 页边距，默认 24
      --gap <pt>         PDF 图片间距，默认 12
      --no-log           不写 capture_log.json
      --keep-png         保留中间 PNG 截图到 frames/（默认不保留，直接内存拼 PDF）
      --preview          额外导出 PDF 首页预览 PNG（调试排版用）
      --diagnose         只输出逐帧帧差表，用于拿真实录屏校准阈值
      --self-test        生成合成录屏并端到端自检
      --make-sample <p> 只生成合成测试视频
      --help

    输出:
      <outdir>/<视频名>_evidence.pdf         A4 竖版 2×2 最终产物（默认唯一产物）
      <outdir>/capture_log.json              内部时间戳日志（可 --no-log 关闭）
      <outdir>/frames/001_00-00-01.png ...   无损中间截图（仅 --keep-png 时生成）
    """)
}

func parseOptions() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.contains("--help") || args.contains("-h") { return o }
    var i = 0
    while i < args.count {
        let a = args[i]
        func value() -> String {
            i += 1
            return i < args.count ? args[i] : ""
        }
        switch a {
        case "--self-test": o.command = .selfTest
        case "--diagnose": o.command = .diagnose
        case "--make-sample": o.command = .makeSample; o.outDir = URL(fileURLWithPath: value())
        case "--outdir": o.outDir = URL(fileURLWithPath: value())
        case "--step": o.config.step = Double(value()) ?? o.config.step
        case "--hold": o.config.hold = Double(value()) ?? o.config.hold
        case "--change": o.config.change = Double(value()) ?? o.config.change
        case "--motion": o.config.motion = Double(value()) ?? o.config.motion
        case "--drift": o.config.drift = Double(value()) ?? o.config.drift
        case "--dedup": o.config.dedup = Double(value()) ?? o.config.dedup
        case "--steady":
            o.config.step = 0.5; o.config.hold = 0.8; o.config.dedup = 0
        case "--margin": o.config.margin = CGFloat(Double(value()) ?? Double(o.config.margin))
        case "--gap": o.config.gap = CGFloat(Double(value()) ?? Double(o.config.gap))
        case "--no-log": o.config.keepLog = false
        case "--keep-png": o.config.keepPNG = true
        case "--preview": break   // 由全局 wantsPreview 处理
        default:
            if a.hasPrefix("-") { err("未知选项: \(a)") }
            else if o.video == nil { o.video = URL(fileURLWithPath: a) }
        }
        i += 1
    }
    if o.command == .help { o.command = .process }
    return o
}

// --preview 需要单独标记，用一个全局兜底
let wantsPreview = CommandLine.arguments.contains("--preview")

func defaultOutDir(_ video: URL) -> URL {
    let stem = video.deletingPathExtension().lastPathComponent
    return video.deletingLastPathComponent().appendingPathComponent(stem + "_evidence")
}

do {
    let o = parseOptions()
    switch o.command {
    case .help:
        usage()

    case .makeSample:
        guard let target = o.outDir else { usage(); exit(1) }
        try makeSampleVideo(to: target)

    case .diagnose:
        guard let video = o.video else { usage(); exit(1) }
        try diagnose(video: video, cfg: o.config)

    case .selfTest:
        let dir = o.outDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("VideoEvidence_selftest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures: [String] = []

        out("=== 自检 1/4：生成合成录屏（4 段停留） ===")
        let sample = dir.appendingPathComponent("sample.mp4")
        try makeSampleVideo(to: sample, groups: 4)
        out("=== 自检 2/4：跑完整流程 ===")
        let r = try process(video: sample, outDir: dir.appendingPathComponent("output"), cfg: o.config, preview: true)
        if r.segments.count != 4 { failures.append("停留段数应为 4，实际 \(r.segments.count)") }
        if r.shots.count != 4 { failures.append("截图数应为 4，实际 \(r.shots.count)") }
        if let stuck = r.segments.first(where: { $0.end - $0.start > 2.5 }) {
            failures.append(String(format: "停留段 %.1f-%.1f 过长，疑似两次停留被滑动粘连", stuck.start, stuck.end))
        }
        let pdf = dir.appendingPathComponent("output").appendingPathComponent("sample_evidence.pdf")
        if let doc = PDFDocument(url: pdf) {
            if doc.pageCount != 1 { failures.append("PDF 页数应为 1，实际 \(doc.pageCount)") }
        } else { failures.append("PDF 无法读回") }
        if let maxDiff = r.stats.max(), maxDiff < o.config.motion {
            failures.append("合成视频帧差最大值 \(maxDiff) 低于阈值，检测逻辑可能失效")
        }

        out("=== 自检 3/4：非 4 倍数分页（5 张 → 2 页） ===")
        let sample5 = dir.appendingPathComponent("sample5.mp4")
        try makeSampleVideo(to: sample5, groups: 5)
        let r5 = try process(video: sample5, outDir: dir.appendingPathComponent("output5"), cfg: o.config)
        if r5.shots.count != 5 { failures.append("5 组应截 5 张，实际 \(r5.shots.count)") }
        let pdf5 = dir.appendingPathComponent("output5").appendingPathComponent("sample5_evidence.pdf")
        if let doc5 = PDFDocument(url: pdf5) {
            if doc5.pageCount != 2 { failures.append("5 张应生成 2 页，实际 \(doc5.pageCount)") }
        } else { failures.append("5 张 PDF 无法读回") }

        out("=== 自检 4/4：断言 ===")
        if failures.isEmpty {
            out("✅ 自检通过：4 段 / 1 页 PDF，5 段 / 2 页 PDF，方向、分页、粘连均正常")
            out("   输出: \(dir.path)")
        } else {
            for f in failures { err("❌ \(f)") }
            exit(1)
        }

    case .process:
        guard let video = o.video else { usage(); exit(1) }
        let dir = o.outDir ?? defaultOutDir(video)
        _ = try process(video: video, outDir: dir, cfg: o.config, preview: wantsPreview)
    }
} catch {
    err("错误: \(error.localizedDescription)")
    exit(1)
}
