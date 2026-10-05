import SwiftUI

/// One session: the conversation thread (prompts, what the agent did, its
/// answers), the composer, and what it waits for. The thread auto-scrolls to
/// the latest exchange, like a chat.
struct SessionDetailView: View {
    let link: PhoneLink
    let sessionId: String

    private var session: SessionItem? { link.sessions.first { $0.id == sessionId } }
    private var turn: TurnSnapshot? { link.turns[sessionId] }

    /// The exchanges, oldest first; the in-progress turn (no history entry yet) shows last.
    private var thread: [TurnSnapshot.TurnEntry] {
        guard let turn else { return [] }
        var entries = turn.history
        let inProgress = turn.endedAt == nil && !(turn.history.last?.startedAt == turn.startedAt)
        if inProgress {
            entries.append(TurnSnapshot.TurnEntry(prompt: turn.prompt, actions: turn.actions,
                                                   files: turn.files, finalMessage: turn.finalMessage,
                                                   startedAt: turn.startedAt, endedAt: turn.endedAt))
        }
        return entries
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let session {
                    VStack(alignment: .leading, spacing: 16) {
                        header(session)
                        if session.needsApproval {
                            ApprovalCard(link: link, session: session)
                        } else if !session.question.isEmpty {
                            waiting(title: "Question", text: session.question, monospaced: false, color: .cyan,
                                    footnote: "Answer on your Mac for now.")
                        }
                        ThreadView(entries: thread, working: session.isWorking)
                        if thread.isEmpty, !session.steps.isEmpty {
                            plan(session)
                        }
                        if thread.isEmpty, !session.finalLine.isEmpty {
                            card(title: "Last message") {
                                Text(session.finalLine)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                        if !session.cwd.isEmpty {
                            card(title: "Folder") {
                                Text(session.cwd)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(16)
                } else if let turn {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("This session ended on your Mac. Its conversation:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ThreadView(entries: thread, working: false)
                    }
                    .padding(16)
                } else {
                    Text("This session ended on your Mac.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                }
            }
            .onChange(of: thread.count) { _, _ in
                // A new exchange arrived: keep the latest visible, like a chat.
                withAnimation { proxy.scrollTo("thread-end", anchor: .bottom) }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    proxy.scrollTo("thread-end", anchor: .bottom)
                }
            }
            // Pinned above the keyboard (and the home indicator), like a real
            // chat composer — it no longer scrolls away with the thread.
            .safeAreaInset(edge: .bottom) {
                if let session, session.acceptsInstructions {
                    InstructionComposer(link: link, session: session)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await link.refresh() }
    }

    private func header(_ session: SessionItem) -> some View {
        HStack(spacing: 16) {
            MochiStill(state: session.state)
                .padding(10)
                .frame(width: 84, height: 84)
                .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(session.pillName) · \(session.title)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.statusColor)
                HStack(spacing: 4) {
                    if !session.macName.isEmpty {
                        Text(session.macName)
                        Text("·")
                    }
                    Text(session.updatedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func waiting(title: String, text: String, monospaced: Bool, color: Color, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            Text(text)
                .font(monospaced ? .callout.monospaced() : .callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                .textSelection(.enabled)
            Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(color.opacity(0.7), lineWidth: 1.5))
    }

    private func plan(_ session: SessionItem) -> some View {
        card(title: "Activity · \(min(session.stepIndex + 1, session.steps.count))/\(session.steps.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: icon(index, session))
                            .foregroundStyle(index == session.stepIndex && session.isWorking ? Color.accentColor : Color.secondary)
                            .font(.footnote)
                        Text(step)
                            .font(.callout)
                            .foregroundStyle(index > session.stepIndex ? Color.secondary : Color.primary)
                    }
                }
            }
        }
    }

    private func icon(_ index: Int, _ session: SessionItem) -> String {
        if index < session.stepIndex || session.state == .finished { return "checkmark.circle.fill" }
        if index == session.stepIndex { return "circle.dotted" }
        return "circle"
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
    }
}

/// The conversation thread: each exchange shows the prompt (right, yours —
/// highlighted when asked from this iPhone), what the agent did (collapsed),
/// and its answer (left). Scrolls like a chat: latest exchange at the bottom.
struct ThreadView: View {
    let entries: [TurnSnapshot.TurnEntry]
    let working: Bool
    @State private var expandedActions: Set<Date> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                ExchangeView(entry: entry, isLast: index == entries.count - 1,
                             working: working,
                             expanded: expandedActions.contains(entry.startedAt)) {
                    toggle(entry.startedAt)
                }
            }
            Color.clear.frame(height: 1).id("thread-end")
        }
    }

    private func toggle(_ date: Date) {
        if expandedActions.contains(date) { expandedActions.remove(date) }
        else { expandedActions.insert(date) }
    }
}

private struct ExchangeView: View {
    let entry: TurnSnapshot.TurnEntry
    let isLast: Bool
    let working: Bool
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Your prompt, right-aligned; iPhone-asked ones get the accent tint.
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    ExpandableText(text: entry.prompt, collapsedLines: 6)
                        .padding(12)
                        .background(entry.fromiPhone
                                    ? Color.accentColor.opacity(0.35)
                                    : Color.accentColor.opacity(0.25),
                                   in: RoundedRectangle(cornerRadius: 16))
                    Text("\(entry.fromiPhone ? "From iPhone" : "You") · \(entry.startedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            // What the agent did: one collapsed line, tap to expand.
            if !entry.actions.isEmpty {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text(expanded ? "Actions · \(entry.actions.count)" : "\(entry.actions.count) actions")
                            .font(.footnote)
                        if entry.actions.contains(where: { $0.failed }) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entry.actions.enumerated()), id: \.offset) { _, action in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: icon(action))
                                    .font(.caption2)
                                    .foregroundStyle(action.failed ? .orange : .secondary)
                                    .padding(.top, 2)
                                Text(action.summary)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(action.failed ? .orange : .secondary)
                                    .lineLimit(3)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            // The agent's answer, left-aligned; spinner while it works.
            if !entry.finalMessage.isEmpty || (isLast && working) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if isLast && working && entry.finalMessage.isEmpty {
                            ProgressView().controlSize(.small)
                            Text("Working…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !entry.finalMessage.isEmpty {
                        ExpandableText(text: entry.finalMessage, collapsedLines: 10, markdown: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func icon(_ action: TurnAction) -> String {
        switch action.tool {
        case "Bash": return action.failed ? "xmark.circle" : "terminal"
        case "Read", "LS": return "doc"
        case "Edit", "Write", "MultiEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        default: return "wrench"
        }
    }
}
