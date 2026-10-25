import Foundation

final class StorageXMLNode {
    let name: String
    var text = ""
    var children: [StorageXMLNode] = []
    init(_ name: String) { self.name = name }
    func child(_ name: String) -> StorageXMLNode? { children.first { $0.name == name } }
    func value(_ name: String) -> String? { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private final class StorageXMLParser: NSObject, XMLParserDelegate {
    let root = StorageXMLNode("root")
    var stack: [StorageXMLNode] = []
    var count = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 32, count < 100_000 else { parser.abortParsing(); return }
        let node = StorageXMLNode(elementName)
        (stack.last ?? root).children.append(node); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

func parseStorageXML(_ data: Data) throws -> StorageXMLNode {
    guard data.count <= 4 * 1024 * 1024,
          let text = String(data: data, encoding: .utf8),
          !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
        throw CoreKitError.remote("Storage returned unsafe or oversized XML.")
    }
    let delegate = StorageXMLParser(), parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
    guard parser.parse(), delegate.stack.isEmpty, let root = delegate.root.children.first else {
        throw CoreKitError.remote("Storage returned malformed XML.")
    }
    return root
}
