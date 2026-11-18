import AppKit
import SwiftUI

/// Sizes of the question card. Its height is worked out from its text before it is
/// drawn, because the overlay's window is sized from the same numbers.
enum QuestionLayout {
    static let pad: CGFloat = 12
    static let titleHeight: CGFloat = 18
    static let buttonsHeight: CGFloat = 26
    static let optionSpacing: CGFloat = 4
    static let optionPad: CGFloat = 6
    static let markWidth: CGFloat = 14
    static let labelHeight: CGFloat = 15
    static let fieldHeight: CGFloat = 28
    /// The question and its options scroll inside the card beyond this.
    static let maxBody: CGFloat = 360

    static func textHeight(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, width: CGFloat) -> CGFloat {
        let box = (text as NSString).boundingRect(
            with: CGSize(width: max(40, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)])
        return ceil(box.height)
    }

    /// Width left for an option's description, inside the card and beside its mark.
    static func detailWidth(card: CGFloat) -> CGFloat { card - pad * 2 - 8 * 2 - markWidth - 8 }

    static func optionHeight(detail: String, card: CGFloat) -> CGFloat {
        optionPad * 2 + labelHeight + (detail.isEmpty ? 0 : 2 + textHeight(detail, size: 10.5, width: detailWidth(card: card)))
    }

    /// The question's text, its options, and the row for typing an answer.
    static func bodyHeight(_ question: ClaudeBridge.AskedQuestion, typing: Bool, card: CGFloat) -> CGFloat {
        var height = textHeight(question.text, size: 12.5, weight: .medium, width: card - pad * 2) + 8
        for option in question.options { height += optionHeight(detail: option.detail, card: card) + optionSpacing }
        height += optionHeight(detail: "", card: card)
        if typing { height += optionSpacing + fieldHeight }
        return height
    }

    /// What the card's measured heights are filed under: one per question showing, with
    /// or without the field for typing, at one width.
    static func key(_ request: ClaudeBridge.PermissionRequest, draft: ClaudeBridge.QuestionDraft?, card: CGFloat) -> String {
        let page = min(max(0, draft?.page ?? 0), request.questions.count - 1)
        let typing = draft?.typing.contains(request.questions[page].id) ?? false
        return "\(request.id)#\(page)#\(typing)#\(Int(card))"
    }

    /// The card's height. `measured` is the height its question and options really took
    /// once drawn; before that, the estimate from the text stands in.
    static func height(_ request: ClaudeBridge.PermissionRequest, draft: ClaudeBridge.QuestionDraft?, card: CGFloat,
                       measured: CGFloat? = nil) -> CGFloat {
        let page = min(max(0, draft?.page ?? 0), request.questions.count - 1)
        let question = request.questions[page]
        let body = measured ?? bodyHeight(question, typing: draft?.typing.contains(question.id) ?? false, card: card)
        return pad + titleHeight + 8 + min(body, maxBody) + 10 + buttonsHeight + pad
    }
}

/// Something Claude asks you, with the answers it offers. One ask can carry several
/// questions; they are shown one at a time and sent together after the last.
struct QuestionCard: View {
    @ObservedObject var store: Store
    let request: ClaudeBridge.PermissionRequest
    /// The card's width, which its height depends on.
    let width: CGFloat
    @FocusState private var typingFocused: Bool

    private var draft: ClaudeBridge.QuestionDraft { store.questionDrafts[request.id] ?? ClaudeBridge.QuestionDraft() }
    private var page: Int { min(max(0, draft.page), request.questions.count - 1) }
    private var question: ClaudeBridge.AskedQuestion { request.questions[page] }
    private var isLast: Bool { page == request.questions.count - 1 }

    var body: some View {
        let question = question
        let typing = draft.typing.contains(question.id)
        let key = QuestionLayout.key(request, draft: draft, card: width)
        let body = store.questionBodies[key] ?? QuestionLayout.bodyHeight(question, typing: typing, card: width)
        VStack(alignment: .leading, spacing: 0) {
            title.frame(height: QuestionLayout.titleHeight)
            ScrollView {
                VStack(alignment: .leading, spacing: QuestionLayout.optionSpacing) {
                    Text(question.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8 - QuestionLayout.optionSpacing)
                    ForEach(question.options, id: \.label) { option in
                        OptionRow(label: option.label, detail: option.detail, multi: question.multiSelect,
                                  selected: draft.picked[question.id]?.contains(option.label) == true) {
                            store.editQuestion(request) { $0.toggle(option.label, in: question) }
                        }
                    }
                    OptionRow(label: "Other", detail: "", multi: question.multiSelect, selected: typing) {
                        store.makeRoom?()
                        withAnimation(Motion.quick) { store.editQuestion(request) { $0.toggleTyping(in: question) } }
                        store.settleWindow?(Motion.settle)
                        typingFocused = !typing
                    }
                    if typing {
                        TextField("Your answer", text: Binding(
                            get: { draft.typed[question.id] ?? "" },
                            set: { text in store.editQuestion(request) { $0.typed[question.id] = text } }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .focused($typingFocused)
                            .onSubmit { store.advanceQuestion(request) }
                            .padding(.horizontal, 9)
                            .frame(height: QuestionLayout.fieldHeight)
                            .background(.white.opacity(0.09), in: squircle(Radius.control))
                            .overlay { squircle(Radius.control).strokeBorder(.white.opacity(typingFocused ? 0.28 : 0.12)) }
                    }
                }
                // Text is measured before it is drawn to size the window, and that estimate
                // can be a line off. What it really took replaces the estimate.
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
                    if store.questionBodies[key] != height { store.questionBodies[key] = height }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(body, QuestionLayout.maxBody))
            .padding(.top, 8)
            buttons.frame(height: QuestionLayout.buttonsHeight).padding(.top, 10)
        }
        .padding(QuestionLayout.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .id(request.id)
    }

    private var title: some View {
        HStack(spacing: 6) {
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Brand.color(.claude).opacity(0.5), in: Capsule())
                    .fixedSize()
            }
            Text("\(store.sessionName(for: request)) asks")
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if request.questions.count > 1 {
                // Says there is more than this one question, and how far along you are.
                Text("\(page + 1) of \(request.questions.count)")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().opacity(0.7)
                    .fixedSize()
                    .accessibilityLabel("Question \(page + 1) of \(request.questions.count)")
            }
        }
    }

    private var buttons: some View {
        let answered = draft.answer(for: question) != nil
        return HStack(spacing: 6) {
            ActionButton("Ask in Claude") { store.answer(request, "ask") }
                .help("Close this and answer in Claude's own window")
            Spacer(minLength: 0)
            if page > 0 {
                ActionButton("Back") { store.animate { store.editQuestion(request) { $0.page -= 1 } } }
            }
            ActionButton(isLast ? "Send" : "Next", prominent: true, tint: Brand.color(.claude)) { store.advanceQuestion(request) }
                .disabled(!answered)
                .opacity(answered ? 1 : 0.45)
                .help(isLast ? "Send your answers to Claude (⌘↩)" : "Next question (⌘↩)")
        }
    }
}

/// One answer to pick. A radio mark where one answer is allowed, a tick box where several are.
private struct OptionRow: View {
    let label: String
    let detail: String
    let multi: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var symbol: String {
        multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .opacity(selected ? 1 : 0.6)
                    .frame(width: QuestionLayout.markWidth, height: QuestionLayout.labelHeight)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .frame(height: QuestionLayout.labelHeight)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 10.5)).opacity(0.72)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, QuestionLayout.optionPad)
            .background(.white.opacity(selected ? 0.18 : hovering ? 0.1 : 0.05), in: squircle(Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "selected" : "not selected")
        .accessibilityHint(detail)
    }
}
