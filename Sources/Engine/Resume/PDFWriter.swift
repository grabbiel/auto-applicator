import AppKit
import CoreText

/// Writes simple, clean letter-size PDFs (cover letters).
public enum PDFWriter {
    public static func letter(_ text: String, title: String) throws -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 72
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: title] as CFDictionary) else {
            throw BrowserError("Couldn't create the PDF.")
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 10
        let font = NSFont(name: "Charter", size: 11.5) ?? NSFont(name: "Georgia", size: 11.5) ?? NSFont.systemFont(ofSize: 11.5)
        let body = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        let setter = CTFramesetterCreateWithAttributedString(body)
        var start = 0
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: page.insetBy(dx: margin, dy: margin), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }
            start += visible.length
        } while start < body.length
        ctx.closePDF()
        return data as Data
    }
}
