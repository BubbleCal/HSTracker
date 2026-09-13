//
//  TrackerFrame.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 31/03/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Cocoa
import TextAttributes

class TextFrame: NSView {

    init() {
        super.init(frame: NSRect.zero)
        initLayers()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        initLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        initLayers()
    }

    func initLayers() {
        self.wantsLayer = true

        self.layer!.backgroundColor = NSColor.clear.cgColor
    }

    func ratio(_ rect: NSRect) -> NSRect {
        return NSRect(x: rect.origin.x / ratioWidth,
                      y: rect.origin.y / ratioHeight,
                      width: rect.size.width / ratioWidth,
                      height: rect.size.height / ratioHeight)
    }

    var ratioWidth: CGFloat {
        switch Settings.cardSize {
        case .tiny: return CGFloat(kRowHeight / kTinyRowHeight)
        case .small: return CGFloat(kRowHeight / kSmallRowHeight)
        case .medium: return CGFloat(kRowHeight / kMediumRowHeight)
        case .huge: return CGFloat(kRowHeight / kHighRowHeight)
        case .big: return 1.0
        }
    }

    var ratioHeight: CGFloat {
        return ratioWidth
    }

    func add(image filename: String, rect: NSRect) {
        let theme = Settings.theme
        guard let rp = Bundle.main.resourcePath else {
            return
        }
        var fullPath = "\(rp)/Resources/Themes/Overlay/\(theme)/\(filename)"
        if !FileManager.default.fileExists(atPath: fullPath) {
            fullPath = "\(rp)/Resources/Themes/Overlay/default/\(filename)"
        }

        guard let image = NSImage(contentsOfFile: fullPath) else {return}
        image.draw(in: ratio(rect))
    }

    func add(int val: Int, rect: NSRect) {
        add(string: "\(val)", rect: rect)
    }

    func add(double val: Double, rect: NSRect) {
        let format = val == Double(Int(val)) ? "%.0f%%" : "%.2f%%"
        add(string: String(format: format, val), rect: rect)
    }

    /// - Parameter shrinkToFit: lower the font size until the text fits on one line
    ///   instead of wrapping out of the frame, for text whose length is not bounded
    ///   (class names, other languages).
    func add(string val: String, rect: NSRect, alignment: NSTextAlignment = .left,
             shrinkToFit: Bool = false) {
        let drawRect = ratio(rect)
        let fullSize = round(18 / ratioHeight)
        func attributes(size: CGFloat) -> TextAttributes {
            return TextAttributes()
                .font(NSFont(name: "ChunkFive", size: size))
                .foregroundColor(.white)
                .strokeColor(.black)
                .strokeWidth(-2)
                .alignment(alignment)
        }

        var size = fullSize
        var string = NSAttributedString(string: val, attributes: attributes(size: size))
        if shrinkToFit {
            let minimumSize = max(8, round(fullSize * 0.5))
            while size > minimumSize && string.size().width > drawRect.width {
                size -= 1
                string = NSAttributedString(string: val, attributes: attributes(size: size))
            }
        }
        // Text is drawn from the top of the rect, so lower a shrunk line by half of
        // the height it lost to keep it centred in the frame.
        var target = drawRect
        if size < fullSize {
            let fullHeight = NSAttributedString(string: val, attributes: attributes(size: fullSize)).size().height
            target.size.height -= max(0, (fullHeight - string.size().height) / 2)
        }
        string.draw(in: target)
    }
}
