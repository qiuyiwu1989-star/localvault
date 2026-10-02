import SwiftUI

// MARK: - 索引侧的正文预览
//
// **提炼页与检索库共用这一个视图。**
// 两处各写一套，口径一定会分叉 —— 这不是担心，是已经发生过的事：
// `VaultQuery.cols` 和 `VaultStore.queryFiles` 各写了一份列清单，
// 改了一份没改另一份，界面上那条路的正文长度全是 0。
//
// 三条口径（改之前先读 `设计契约.md` §8）：
//   ① 正文只从索引读，**不读原文件** —— 所以「agent 搜得到的」和「你看得见的」是同一份
//   ② 空正文有五种原因，必须说清是哪一种，不能只说「没有正文」
//   ③ 两层截断（列表 4000 / 存储 400000）的措辞不能混，撞上限要报「以上」

struct IndexedPreview: View {

    let fileId: Int64
    let dbPath: String
    /// 用于「在访达中显示」。没有就不显示那个按钮。
    var path: String? = nil
    /// 窄栏里收紧留白。
    var compact = false

    private var pad: CGFloat { compact ? Space.sm : Space.md }

    @State private var text = ""
    @State private var truncated = false
    @State private var denied = false
    @State private var loading = false
    @State private var raw = ContentView.initialRaw

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if truncated { note("索引里这篇正文被截断了（单篇上限 40 万字符）—— 下面不是全文。") }
            if denied {
                note("这个文件按规则不读正文，索引里只留了元数据。")
            } else if text.isEmpty && !loading {
                note("索引里没有正文 —— 可能是二进制、或是文字类但超出单篇提取上限。")
            } else {
                ScrollView {
                    Group {
                        if raw {
                            // 原文必须原样输出：走 Markdown 会把 `*` `_` `#` 当格式吃掉
                            Text(text)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownText(text)
                        }
                    }
                    .padding(.horizontal, pad)
                    .padding(.bottom, pad)
                }
            }
        }
        .task(id: fileId) { await load(fileId) }
    }

    private var header: some View {
        HStack(spacing: Space.xs) {
            SubHead("正文")
            if loading { ProgressView().controlSize(.small) }
            Spacer(minLength: Space.xs)
            Picker("", selection: $raw) {
                Text("渲染").tag(false)
                Text("原文").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 104)
            .help("切 Markdown 渲染 / 原始文本")

            if let path {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在访达中显示（本 App 不会改动它）")
            }
        }
        .padding(.horizontal, pad)
        .padding(.vertical, Space.xs)
    }

    private func note(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, pad)
            .padding(.bottom, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 连点两个文件时，先发的慢查询可能后回来。不挡的话会把后点的那篇盖掉。
    private func load(_ id: Int64) async {
        loading = true
        let db = dbPath
        let d = await Task.detached(priority: .userInitiated) {
            VaultQuery.bodyDetail(dbPath: db, id: id)
        }.value
        guard fileId == id else { return }
        text = d.body
        truncated = d.truncated
        denied = d.denied
        loading = false
    }
}
