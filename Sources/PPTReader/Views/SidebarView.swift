import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    let onCollapse: () -> Void
    @ViewState private var query = ""
    @ViewState private var expanded: Set<URL> = []
    @ViewState private var expandedRoot: URL?
    @Namespace private var selection

    var body: some View {
        let library = model.library

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                Button(action: onCollapse) {
                    Label(tr("隐藏侧边栏", "Hide Sidebar"), systemImage: "sidebar.left")
                }
                .buttonStyle(IconButtonStyle())
                .help(tr("隐藏侧边栏", "Hide sidebar") + " ⌃⌘S")
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.barHeight)
            .background(WindowDragArea())

            if let root = library.rootURL {
                FolderMenu(root: root)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                SearchField(text: $query)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if library.nodes.isEmpty {
                            hint(library.isScanning ? tr("正在扫描…", "Scanning…") : tr("没有课件", "No course files"))
                        } else if query.isEmpty {
                            ForEach(visibleRows(library.nodes), id: \.node.id) { row in
                                TreeRow(node: row.node, depth: row.depth,
                                        isExpanded: expanded.contains(row.node.url),
                                        isSelected: model.selectedFile == row.node.url,
                                        selection: selection) { activate(row.node) }
                                    .popContextMenu { contextItems(for: row.node) }
                                    .transition(.opacity.combined(with: .offset(y: -4)))
                            }
                        } else {
                            let matches = library.nodes.flatMap(\.allFiles)
                                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                            if matches.isEmpty { hint(tr("无匹配", "No matches")) }
                            ForEach(matches) { node in
                                TreeRow(node: node, depth: 0, isExpanded: false,
                                        isSelected: model.selectedFile == node.url,
                                        selection: selection,
                                        subtitle: relativeFolder(of: node, root: root)) { activate(node) }
                                    .popContextMenu { contextItems(for: node) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            } else {
                VStack(spacing: 10) {
                    Text(tr("未打开文件夹", "No folder open"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text2)
                    Button(tr("打开文件夹…", "Open Folder…")) { model.chooseFolder() }
                        .buttonStyle(OutlineButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
            footer
        }
        .background(Theme.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.openFolder(url)
            return true
        }
        .onAppear(perform: expandDefaults)
        .onChange(of: library.nodes) { expandDefaults() }
        .onChange(of: model.selectedFile) { revealSelection() }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { model.chooseFolder() } label: {
                Label(tr("打开文件夹", "Open Folder"), systemImage: "folder.badge.plus")
            }
            .buttonStyle(IconButtonStyle())
            .help(tr("打开文件夹", "Open folder") + " ⌘O")
            Button { SettingsWindow.show() } label: {
                Label(tr("设置", "Settings"), systemImage: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help(tr("设置", "Settings") + " ⌘,")
            Spacer()
            if model.library.rootURL != nil {
                Text(tr("\(model.library.fileCount) 个课件", model.library.fileCount == 1 ? "1 file" : "\(model.library.fileCount) files"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    private func contextItems(for node: FileNode) -> [PopMenuItem] {
        var items: [PopMenuItem] = []
        if node.isFolder {
            let open = expanded.contains(node.url)
            items.append(PopMenuItem(open ? tr("折叠", "Collapse") : tr("展开", "Expand"), icon: open ? "chevron.up" : "chevron.down") { activate(node) })
        } else {
            items.append(PopMenuItem(tr("打开", "Open"), icon: "doc.text") { activate(node) })
            items.append(PopMenuItem(tr("用默认应用打开", "Open in Default App"), icon: "arrow.up.forward.app") { NSWorkspace.shared.open(node.url) })
        }
        items += [
            .separator,
            PopMenuItem(tr("在访达中显示", "Show in Finder"), icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) },
            PopMenuItem(tr("拷贝路径", "Copy Path"), icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            },
        ]
        return items
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private struct Row {
        let node: FileNode
        let depth: Int
    }

    private func visibleRows(_ nodes: [FileNode], depth: Int = 0) -> [Row] {
        nodes.flatMap { node -> [Row] in
            var rows = [Row(node: node, depth: depth)]
            if let children = node.children, expanded.contains(node.url) {
                rows += visibleRows(children, depth: depth + 1)
            }
            return rows
        }
    }

    private func activate(_ node: FileNode) {
        withAnimation(Motion.snappy) {
            if node.isFolder {
                if expanded.contains(node.url) { expanded.remove(node.url) } else { expanded.insert(node.url) }
            } else {
                model.selectedFile = node.url
            }
        }
    }

    private func relativeFolder(of node: FileNode, root: URL) -> String? {
        let folder = node.url.deletingLastPathComponent().path
        guard folder.count > root.path.count else { return nil }
        return String(folder.dropFirst(root.path.count + 1))
    }

    /// 新打开的文件夹默认展开第一层，以及当前课件所在的路径。
    private func expandDefaults() {
        let library = model.library
        guard !library.nodes.isEmpty, expandedRoot != library.rootURL else { return }
        expandedRoot = library.rootURL
        expanded = Set(library.nodes.filter(\.isFolder).map(\.url))
        revealSelection()
    }

    private func revealSelection() {
        guard let selected = model.selectedFile, let root = model.library.rootURL else { return }
        var url = selected.deletingLastPathComponent()
        while url.path.count > root.path.count {
            expanded.insert(url)
            url = url.deletingLastPathComponent()
        }
    }
}

/// 课程文件夹名称，点按可切换文件夹。
private struct FolderMenu: View {
    @Environment(AppModel.self) private var model
    let root: URL

    var body: some View {
        PopMenuButton(style: HoverRowStyle(), items: items) {
            HStack(spacing: 5) {
                Text(root.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .help(root.path)
    }

    private func items() -> [PopMenuItem] {
        var items: [PopMenuItem] = []
        let others = model.library.recentFolders.filter { $0 != root }
        if !others.isEmpty {
            items.append(.header(tr("最近打开", "Recent")))
            items += others.map { url in
                PopMenuItem(url.lastPathComponent, icon: "clock") { model.openFolder(url) }
            }
            items.append(.separator)
        }
        items += [
            PopMenuItem(tr("打开其他文件夹…", "Open Folder…"), icon: "folder.badge.plus", shortcut: "⌘O") { model.chooseFolder() },
            PopMenuItem(tr("刷新", "Refresh"), icon: "arrow.clockwise", shortcut: "⌘R") { model.library.refresh() },
            PopMenuItem(tr("在访达中显示", "Show in Finder"), icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([root]) },
        ]
        return items
    }
}

private struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? Theme.selected : (hovering ? Theme.hover : .clear))
                )
                .onHover { hovering = $0 }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
            TextField(tr("搜索", "Search"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1)
        )
        .animation(Motion.hover, value: focused)
    }
}

private struct TreeRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let selection: Namespace.ID
    var subtitle: String?
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if node.isFolder {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10)

                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.text2)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 0) {
                    Text(node.isFolder ? node.name : node.url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(Theme.text.opacity(isSelected ? 1 : 0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6 + CGFloat(depth) * 14)
            .padding(.trailing, 8)
            .frame(height: subtitle == nil ? 28 : 38)
            .background {
                // 选中高亮在行之间滑动
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.selected)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.hover)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(node.name)
    }

    private var symbol: String {
        switch node.kind {
        case .folder: "folder"
        case .pdf: "doc.text"
        case .slides: "rectangle.on.rectangle"
        case .document: "doc.plaintext"
        }
    }
}
