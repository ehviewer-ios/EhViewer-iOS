import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 导入 Android SharedPreferences XML（`shared_prefs/<package>_preferences.xml`），用于从 Android 迁移设置。
extension EhSettings {
    /// 解析 Android 偏好 XML，按原类型写入 UserDefaults。省略项（`omittedAndroidKeys`）跳过。
    /// - Parameter keys: 只导入这些 key；nil 表示全部
    /// - Returns: 导入的条目数
    @discardableResult
    public func importAndroidPreferences(xml data: Data, keys: Set<String>? = nil) throws -> Int {
        let entries = try AndroidPreferencesParser.parse(data)
        let omitted = Set(Self.omittedAndroidKeys)
        var count = 0
        for (key, value) in entries where !omitted.contains(key) {
            if let keys, !keys.contains(key) { continue }
            switch value {
            case let .string(s): defaults.set(s, forKey: key)
            case let .bool(b): defaults.set(b, forKey: key)
            case let .int(i): defaults.set(i, forKey: key)
            case let .long(l): defaults.set(l, forKey: key)
            case let .float(f): defaults.set(f, forKey: key)
            case let .stringSet(set): defaults.set(set, forKey: key)
            }
            count += 1
        }
        return count
    }
}

/// Android SharedPreferences XML 值
public enum AndroidPreferenceValue: Sendable, Hashable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case long(Int64)
    case float(Float)
    case stringSet([String])
}

/// 解析 `<map><string name="k">v</string><boolean name="k" value="true"/>…</map>`
public enum AndroidPreferencesParser {
    public static func parse(_ data: Data) throws -> [(String, AndroidPreferenceValue)] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw EhStorageError.cantReadFile(parser.parserError.map { String(describing: $0) } ?? "xml")
        }
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [(String, AndroidPreferenceValue)] = []
        private var currentName: String?
        private var currentElement: String?
        private var text = ""
        private var setName: String?
        private var setItems: [String] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            let name = attributeDict["name"]
            let value = attributeDict["value"]
            switch elementName {
            case "set":
                setName = name
                setItems = []
            case "string":
                currentElement = "string"
                currentName = name
            case "boolean":
                if let name, let value { entries.append((name, .bool(value == "true"))) }
            case "int":
                if let name, let value, let v = Int(value) { entries.append((name, .int(v))) }
            case "long":
                if let name, let value, let v = Int64(value) { entries.append((name, .long(v))) }
            case "float":
                if let name, let value, let v = Float(value) { entries.append((name, .float(v))) }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch elementName {
            case "string":
                if setName != nil {
                    setItems.append(text)
                } else if let name = currentName {
                    entries.append((name, .string(text)))
                }
                currentName = nil
                currentElement = nil
            case "set":
                if let name = setName { entries.append((name, .stringSet(setItems))) }
                setName = nil
            default:
                break
            }
            text = ""
        }
    }
}
